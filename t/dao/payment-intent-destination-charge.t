# ABOUTME: Tests that create_payment_intent produces Stripe Connect destination-charge params
# ABOUTME: when a tenant_slug in metadata resolves to an account with stripe_connect_account_id.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
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
use Test::Registry::Async qw( settle );

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

# Link the tenant to the seeded 2% revenue-share plan. A freshly provisioned
# tenant has platform_pricing_plan_id NULL (the one-time backfill ran before it
# existed), so the resolver would otherwise fall back to the Free 0% plan.
my $two_pct_plan_id = $db->query(q{
    SELECT id FROM registry.pricing_plans
     WHERE plan_scope = 'tenant'
       AND pricing_model_type = 'percentage'
       AND metadata->>'default' IS DISTINCT FROM 'true'
     ORDER BY created_at
     LIMIT 1
})->hash->{id};
ok $two_pct_plan_id, 'seeded 2% revenue-share plan found';
$db->query(
    'UPDATE registry.tenants SET platform_pricing_plan_id = $1 WHERE slug = $2',
    $two_pct_plan_id, $slug,
);

# Expected application fee for a $100.00 charge at the 2% plan rate:
# int(10000 * 0.02 + 0.5) = 200 cents.
my $expected_fee_2pct = int(10000 * 0.02 + 0.5);

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
    # The fee is now a plain fraction-of-cents computation, rounded half-up.
    # Amounts that round to a 0 fee are acceptable; Stripe forbids the fee
    # exceeding the charge, never an issue at these rates.
    is Registry::DAO::Payment::application_fee_cents(10000, 0.02), 200,
        '$100.00 (10000 cents) at 2% -> 200 cents fee';
    is Registry::DAO::Payment::application_fee_cents(999, 0.02),   20,
        '$9.99 (999 cents) at 2% -> 20 cents fee (rounded half-up)';
    is Registry::DAO::Payment::application_fee_cents(1, 0.02),      0,
        '$0.01 (1 cent) at 2% -> 0 cents fee';
    is Registry::DAO::Payment::application_fee_cents(10000, 0.00),  0,
        '$100.00 (10000 cents) at 0% (Free) -> 0 cents fee';
};

# ---- the constant must be gone -----------------------------------------------
ok !Registry::DAO::Payment->can('REVENUE_SHARE_PERCENT'),
    'REVENUE_SHARE_PERCENT constant removed from Payment';

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
    is $captured->{'application_fee_amount'}, $expected_fee_2pct,
        'application_fee_amount is 2% of 10000 cents = 200';
};

# ---- (a2) tenant with NULL plan link -> Free 0% fee, destination still set ------
subtest 'tenant with NULL platform_pricing_plan_id -> 0 fee (Free fallback)' => sub {
    # A second connect-ready tenant with no linked plan: the resolver falls back
    # to the platform Free plan (0%), so the application fee is 0 while the
    # destination-charge routing params are still present.
    my $free_slug  = 'free_charge_' . $$;
    my $free_admin = Registry::DAO::User->create($db, {
        username  => "free_admin_$$",
        email     => "free_admin_$$\@test.example",
        name      => 'Free Admin',
        user_type => 'admin',
    });
    my $free_tenant = Registry::DAO::Tenant->provision($db, {
        name  => "Free Test $$",
        slug  => $free_slug,
        users => [ $free_admin ],
    });
    $db->query(
        'UPDATE registry.tenants SET stripe_connect_account_id = $1, stripe_charges_enabled = TRUE, stripe_details_submitted = TRUE, platform_pricing_plan_id = NULL WHERE slug = $2',
        'acct_free123', $free_slug,
    );

    my $free_dao = Registry::DAO->new(url => $test_db->uri, schema => $free_slug);
    my $free_db  = $free_dao->db;
    my $free_parent = Registry::DAO::User->create($free_db, {
        username  => "free_parent_$$",
        email     => "free_parent_$$\@test.example",
        name      => 'Free Parent',
        user_type => 'parent',
    });

    my $payment = Registry::DAO::Payment->create($free_db, {
        user_id  => $free_parent->id,
        amount   => 100.00,
        metadata => {
            tenant_slug      => $free_slug,
            enrollment_items => [],
        },
    });

    my $captured;
    {
        no warnings 'redefine';
        local *Registry::Service::Stripe::create_payment_intent = sub {
            my ($self, $params) = @_;
            $captured = $params;
            return { id => 'pi_free_123', client_secret => 'cs_free_123' };
        };
        local $ENV{STRIPE_SECRET_KEY} = 'sk_test_dummy';
        $payment->create_payment_intent($free_db, {
            description => 'Free-plan destination charge',
        });
    }

    ok $captured, 'stripe client received params';
    is $captured->{'transfer_data[destination]'}, 'acct_free123',
        'transfer_data[destination] still set for NULL-plan tenant';
    is $captured->{'on_behalf_of'}, 'acct_free123',
        'on_behalf_of still set for NULL-plan tenant';
    is $captured->{'application_fee_amount'}, 0,
        'application_fee_amount is 0 (Free plan) for NULL-plan tenant';
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
    # Build a real Payment with tenant_slug in metadata. Leave
    # Registry::DAO::Payment::find REAL so the payment (and its metadata) is
    # reloaded from the DB and round-trips through the jsonb -> ADJUST decode
    # path before _connect_params reads tenant_slug. Stub only the
    # processing/network edges so handle_payment_callback reaches the retry
    # branch without touching the real Stripe API.

    # Create a minimal workflow + run in the tenant schema for handle_payment_callback.
    my $workflow = Registry::DAO::Workflow->create($tenant_db, {
        name        => 'DC Retry Workflow',
        slug        => "dc-retry-workflow-$$",
        description => 'Retry path test workflow',
    });
    Registry::DAO::WorkflowStep->create($tenant_db, {
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

    my $retry_captured;
    {
        no warnings qw(redefine once);
        # Leave Registry::DAO::Payment::find REAL so the payment (and its
        # metadata) is reloaded from the DB and round-trips through the
        # jsonb -> ADJUST decode path before _connect_params reads tenant_slug.
        # intent_status must be the terminal decline state: only
        # requires_payment_method / canceled earn a fresh intent, so
        # omitting it would skip the retry branch this subtest exists to
        # cover.
        local *Registry::DAO::Payment::process_payment_async = sub {
            Mojo::Promise->resolve({
                success       => 0,
                error         => 'Card declined',
                intent_status => 'requires_payment_method',
            });
        };
        local *Registry::Service::Stripe::create_payment_intent_async = sub {
            my ($self, $params) = @_;
            $retry_captured = $params;
            return Mojo::Promise->resolve(
                { id => 'pi_dc_retry', client_secret => 'cs_dc_retry' });
        };
        local $ENV{STRIPE_SECRET_KEY} = 'sk_test_dummy';
        settle($step->handle_payment_callback($tenant_db, $run, {
            payment_intent_id => 'pi_dc_initial',
        }));
    }

    ok $retry_captured, 'retry intent was requested';
    is $retry_captured->{'transfer_data[destination]'}, 'acct_test123',
        'retry intent carries same destination account';
    is $retry_captured->{'on_behalf_of'}, 'acct_test123',
        'retry intent carries same on_behalf_of';
    is $retry_captured->{'application_fee_amount'}, $expected_fee_2pct,
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
    is $async_captured->{'application_fee_amount'}, $expected_fee_2pct,
        'async: application_fee_amount is 200 cents';
};

$test_db->cleanup_test_database;
done_testing;
