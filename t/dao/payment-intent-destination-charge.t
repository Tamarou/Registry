# ABOUTME: Tests that create_payment_intent produces Stripe Connect destination-charge params
# ABOUTME: when a tenant_slug in metadata resolves to an account with stripe_connect_account_id.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::MockObject;
use Test::Registry::DB;
use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::Payment;
use Registry::DAO::WorkflowSteps::Payment;
use Registry::Service::Stripe;
use Mojo::Promise;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

# Provision a tenant so registry.tenants row exists and schema is cloned.
my $slug  = 'dest_charge_' . $$;
my $admin = Registry::DAO::User->create($db, {
    username  => "dc_admin_$$",
    email     => "dc_admin_$$\@test.example",
    name      => 'DC Admin',
    user_type => 'admin',
});

my $tenant = Registry::DAO::Tenant->provision($db, {
    name  => "DC Test $$",
    slug  => $slug,
    users => [ $admin ],
});
ok $tenant, 'tenant provisioned';

# Set stripe_connect_account_id so create_payment_intent can derive connect params.
$db->query(
    'UPDATE registry.tenants SET stripe_connect_account_id = $1, stripe_charges_enabled = TRUE, stripe_details_submitted = TRUE WHERE slug = $2',
    'acct_test123', $slug,
);

my $tenant_dao = Registry::DAO->new(url => $test_db->uri, schema => $slug);
my $tenant_db  = $tenant_dao->db;

my $parent = Registry::DAO::User->create($tenant_db, {
    username  => "dc_parent_$$",
    email     => "dc_parent_$$\@test.example",
    name      => 'DC Parent',
    user_type => 'parent',
});

# ---- (e) unit tests for application_fee_cents ---------------------------------
subtest 'application_fee_cents unit tests' => sub {
    # Amounts under $0.40 round to a 0 fee -- acceptable; Stripe forbids the
    # fee exceeding the charge, never an issue at 2.5%.
    is Registry::DAO::Payment::application_fee_cents(10000), 250,
        '$100.00 (10000 cents) -> 250 cents fee';
    is Registry::DAO::Payment::application_fee_cents(999),   25,
        '$9.99 (999 cents) -> 25 cents fee (floor at half-up)';
    is Registry::DAO::Payment::application_fee_cents(1),      0,
        '$0.01 (1 cent) -> 0 cents fee';
    is Registry::DAO::Payment::application_fee_cents(100),    3,
        '$1.00 (100 cents) -> 3 cents fee (rounded half-up)';
};

# ---- (a) tenant payment: connect params present --------------------------------
subtest 'tenant payment with connect account -> destination charge params' => sub {
    my $payment = Registry::DAO::Payment->create($tenant_db, {
        user_id  => $parent->id,
        amount   => 100.00,
        metadata => {
            tenant_slug      => $slug,
            enrollment_items => [],
        },
    });

    my $captured;
    {
        no warnings 'redefine';
        local *Registry::Service::Stripe::create_payment_intent = sub {
            my ($self, $params) = @_;
            $captured = $params;
            return { id => 'pi_dest_123', client_secret => 'cs_dest_123' };
        };
        local $ENV{STRIPE_SECRET_KEY} = 'sk_test_dummy';
        $payment->create_payment_intent($tenant_db, {
            description   => 'Test destination charge',
            receipt_email => 'dc@test.example',
        });
    }

    ok $captured, 'stripe client received params';
    is $captured->{'transfer_data[destination]'}, 'acct_test123',
        'transfer_data[destination] is the tenant connect account';
    is $captured->{'on_behalf_of'}, 'acct_test123',
        'on_behalf_of is the tenant connect account';
    is $captured->{'application_fee_amount'}, 250,
        'application_fee_amount is 2.5% of 10000 cents = 250';
};

# ---- (b) platform payment (no tenant_slug): no connect params ------------------
subtest 'platform payment without tenant_slug -> no connect params' => sub {
    my $platform_user = Registry::DAO::User->create($db, {
        username  => "dc_platform_$$",
        email     => "dc_platform_$$\@test.example",
        name      => 'DC Platform User',
        user_type => 'admin',
    });

    my $payment = Registry::DAO::Payment->create($db, {
        user_id  => $platform_user->id,
        amount   => 50.00,
        metadata => { some_key => 'some_value' },
    });

    my $captured;
    {
        no warnings 'redefine';
        local *Registry::Service::Stripe::create_payment_intent = sub {
            my ($self, $params) = @_;
            $captured = $params;
            return { id => 'pi_platform_123', client_secret => 'cs_platform_123' };
        };
        local $ENV{STRIPE_SECRET_KEY} = 'sk_test_dummy';
        $payment->create_payment_intent($db, {
            description => 'Platform charge (no connect)',
        });
    }

    ok $captured, 'stripe client received params';
    ok !exists $captured->{'transfer_data[destination]'},
        'no transfer_data[destination] for platform payment';
    ok !exists $captured->{'on_behalf_of'},
        'no on_behalf_of for platform payment';
    ok !exists $captured->{'application_fee_amount'},
        'no application_fee_amount for platform payment';
};

# ---- (c) retry path: handle_payment_callback failure re-issues same connect params ----
subtest 'retry intent carries same connect params as original' => sub {
    # Build a real Payment with tenant_slug in metadata, then mock process_payment
    # to return a failure (avoiding the save() call in the real method) so that
    # handle_payment_callback reaches the retry branch. Intercept
    # create_payment_intent to capture what params the retry intent receives.
    # This proves that the derive-inside design routes the retry correctly even
    # without any connect params being passed by the caller.

    # Create a minimal workflow + run in the tenant schema for handle_payment_callback.
    my $workflow = Registry::DAO::Workflow->create($tenant_db, {
        name        => 'DC Retry Workflow',
        slug        => "dc-retry-workflow-$$",
        description => 'Retry path test workflow',
    });
    my $pay_step_row = Registry::DAO::WorkflowStep->create($tenant_db, {
        workflow_id => $workflow->id,
        slug        => 'payment',
        class       => 'Registry::DAO::WorkflowSteps::Payment',
        description => 'Payment step',
    });
    $workflow->update($tenant_db, { first_step => 'payment' }, { id => $workflow->id });

    # Create a real payment with tenant_slug in metadata so _connect_params can look it up.
    my $real_payment = Registry::DAO::Payment->create($tenant_db, {
        user_id  => $parent->id,
        amount   => 100.00,
        metadata => {
            tenant_slug      => $slug,
            enrollment_items => [],
        },
    });

    my $run = $workflow->new_run($tenant_db);
    $run->update_data($tenant_db, {
        user_id    => $parent->id,
        payment_id => $real_payment->id,
    });

    my $step = $workflow->get_step($tenant_db, { slug => 'payment' });

    # Build a mock Payment that wraps the real payment for process_payment only;
    # create_payment_intent is left as the real method so we can verify its params.
    my $mock = Test::MockObject->new;
    $mock->set_always('id',             $real_payment->id);
    $mock->set_always('process_payment', { success => 0, error => 'Card declined' });
    $mock->mock('finalize_enrollment',  sub { });
    # Delegate create_payment_intent to the real object so _connect_params runs.
    $mock->mock('create_payment_intent', sub { shift; $real_payment->create_payment_intent(@_) });

    my $retry_captured;
    {
        no warnings qw(redefine once);
        local *Registry::DAO::Payment::find = sub { $mock };
        local *Registry::Service::Stripe::create_payment_intent = sub {
            my ($self, $params) = @_;
            $retry_captured = $params;
            return { id => 'pi_dc_retry', client_secret => 'cs_dc_retry' };
        };
        local $ENV{STRIPE_SECRET_KEY} = 'sk_test_dummy';
        $step->handle_payment_callback($tenant_db, $run, {
            payment_intent_id => 'pi_dc_initial',
        });
    }

    ok $retry_captured, 'retry intent was requested';
    is $retry_captured->{'transfer_data[destination]'}, 'acct_test123',
        'retry intent carries same destination account';
    is $retry_captured->{'on_behalf_of'}, 'acct_test123',
        'retry intent carries same on_behalf_of';
    is $retry_captured->{'application_fee_amount'}, 250,
        'retry intent carries same application_fee_amount';
};

# ---- (d) async parity: create_payment_intent_async also carries connect params -----
subtest 'async create_payment_intent_async carries connect params for tenant payment' => sub {
    my $payment = Registry::DAO::Payment->create($tenant_db, {
        user_id  => $parent->id,
        amount   => 100.00,
        metadata => {
            tenant_slug      => $slug,
            enrollment_items => [],
        },
    });

    my $async_captured;
    {
        no warnings 'redefine';
        local *Registry::Service::Stripe::create_payment_intent_async = sub {
            my ($self, $params) = @_;
            $async_captured = $params;
            return Mojo::Promise->resolve({ id => 'pi_async_dest', client_secret => 'cs_async_dest' });
        };
        local $ENV{STRIPE_SECRET_KEY} = 'sk_test_dummy';
        $payment->create_payment_intent_async($tenant_db, { description => 'Async test' })->wait;
    }

    ok $async_captured, 'async stripe client received params';
    is $async_captured->{'transfer_data[destination]'}, 'acct_test123',
        'async: transfer_data[destination] is the tenant connect account';
    is $async_captured->{'on_behalf_of'}, 'acct_test123',
        'async: on_behalf_of is the tenant connect account';
    is $async_captured->{'application_fee_amount'}, 250,
        'async: application_fee_amount is 250 cents';
};

$test_db->cleanup_test_database;
done_testing;
