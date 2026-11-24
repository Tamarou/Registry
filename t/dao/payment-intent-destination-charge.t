# ABOUTME: Tests that create_payment_intent makes a direct charge on the seller's own Stripe
# ABOUTME: account: a client bound to it, the platform fee, and no transfer_data or on_behalf_of.
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
use Test::Registry::PricingProbe qw( give_tenant_terms );

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

# State the platform terms the tenant charges under. A tenant provisioned
# directly like this holds none, so the charge would otherwise be refused. The rate is this test's own, not the launch decision's, so
# the expected fee follows from what the test stated.
my $stated_rate = '0.0137';
give_tenant_terms( $db, $slug, { rate => $stated_rate } );

# Expected application fee for a $100.00 charge at the stated rate. The half-up
# rule itself is unit-tested against literals below, which is where it belongs.
my $expected_fee =
    Registry::DAO::Payment::application_fee_cents( 10000, $stated_rate );

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
    # The fee is a plain fraction-of-cents computation, rounded half to even.
    # Amounts that round to a 0 fee are acceptable; Stripe forbids the fee
    # exceeding the charge, never an issue at these rates.
    is Registry::DAO::Payment::application_fee_cents(10000, 0.02), 200,
        '$100.00 (10000 cents) at 2% -> 200 cents fee';
    is Registry::DAO::Payment::application_fee_cents(999, 0.02),   20,
        '$9.99 (999 cents) at 2% -> 20 cents fee (19.98 rounded)';
    is Registry::DAO::Payment::application_fee_cents(1, 0.02),      0,
        '$0.01 (1 cent) at 2% -> 0 cents fee';
    is Registry::DAO::Payment::application_fee_cents(10000, 0.00),  0,
        '$100.00 (10000 cents) at 0% (Free) -> 0 cents fee';
};

subtest 'a fee landing on a half cent rounds to the even cent (ruling 7c)' => sub {
    is Registry::DAO::Payment::application_fee_cents(1020, 0.025), 26,
        '2.5% of 1020 = 25.5 -> 26';
    is Registry::DAO::Payment::application_fee_cents(1060, 0.025), 26,
        '2.5% of 1060 = 26.5 -> 26';
    # 600 * 0.0175 is 10.500000000000002 in binary floating point.
    is Registry::DAO::Payment::application_fee_cents(600, 0.0175), 10,
        '1.75% of 600 = 10.5 -> 10, with no binary-float error';
};

# ---- the constant must be gone -----------------------------------------------
ok !Registry::DAO::Payment->can('REVENUE_SHARE_PERCENT'),
    'REVENUE_SHARE_PERCENT constant removed from Payment';

# ---- (a) tenant payment: a direct charge on the tenant's account ---------------
subtest 'tenant intent is a direct charge on its own account' => sub {
    my $payment = Registry::DAO::Payment->create($tenant_db, {
        user_id  => $parent->id,
        amount_cents => 10000,
        metadata => {
            tenant_slug      => $slug,
            enrollment_items => [],
        },
    });

    my ($captured, $account);
    {
        no warnings 'redefine';
        local *Registry::Service::Stripe::create_payment_intent = sub {
            my ($self, $params) = @_;
            $captured = $params;
            $account  = $self->stripe_account;
            return { id => 'pi_dest_123', client_secret => 'cs_dest_123' };
        };
        local $ENV{STRIPE_SECRET_KEY} = 'sk_test_dummy';
        $payment->create_payment_intent($tenant_db, {
            description   => 'Test destination charge',
            receipt_email => 'dc@test.example',
        });
    }

    ok $captured, 'stripe client received params';
    is $account, 'acct_test123',
        'the creating client is bound to the tenant connect account';
    ok !exists $captured->{'transfer_data[destination]'},
        'no transfer_data[destination]: the charge is already on the tenant account';
    ok !exists $captured->{'on_behalf_of'},
        'no on_behalf_of: the tenant is the merchant by being the account charged';
    is $captured->{'application_fee_amount'}, $expected_fee,
        "application_fee_amount is the stated rate on 10000 cents ($expected_fee)";
};

# ---- (a2) tenant with no platform entitlement -> refused, never a 0 fee -------
subtest 'tenant with no platform entitlement is refused before stripe' => sub {
    # A second connect-ready tenant holding no platform entitlement. Absence is
    # not zero: there is no Free plan to fall back to, so the charge is refused
    # naming the tenant before any row is written or Stripe is asked.
    my $bare_slug  = 'bare_charge_' . $$;
    my $bare_admin = Registry::DAO::User->create($db, {
        username  => "bare_admin_$$",
        email     => "bare_admin_$$\@test.example",
        name      => 'Bare Admin',
        user_type => 'admin',
    });
    Registry::DAO::Tenant->provision($db, {
        name  => "Bare Test $$",
        slug  => $bare_slug,
        users => [ $bare_admin ],
    });
    $db->query(
        'UPDATE registry.tenants SET stripe_connect_account_id = $1, stripe_charges_enabled = TRUE, stripe_details_submitted = TRUE WHERE slug = $2',
        'acct_bare123', $bare_slug,
    );

    my $bare_db = Registry::DAO->new(url => $test_db->uri, schema => $bare_slug)->db;
    my $bare_parent = Registry::DAO::User->create($bare_db, {
        username  => "bare_parent_$$",
        email     => "bare_parent_$$\@test.example",
        name      => 'Bare Parent',
        user_type => 'parent',
    });

    my $requests = 0;
    no warnings 'redefine';
    local *Registry::Service::Stripe::_request_async = sub {
        $requests++;
        return Mojo::Promise->resolve({ id => 'pi_never', client_secret => 'cs_never' });
    };
    local $ENV{STRIPE_SECRET_KEY} = 'sk_test_dummy';

    my $ok = eval {
        Registry::DAO::Payment->create($bare_db, {
            user_id      => $bare_parent->id,
            amount_cents => 10000,
            metadata     => { tenant_slug => $bare_slug, enrollment_items => [] },
        })->create_payment_intent($bare_db, { description => 'No terms' });
        1;
    };
    ok !$ok, 'the charge is refused';
    like $@, qr/'\Q$bare_slug\E' holds no platform entitlement/, 'naming the tenant';
    is $bare_db->query('SELECT count(*) FROM payments')->array->[0], 0, 'no payment row is written';
    is $requests, 0, 'and no request reached Stripe';
};

# ---- (c) retry path: handle_payment_callback failure re-issues same connect params ----
subtest 'retry intent is a direct charge on the same account' => sub {
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
        amount_cents => 10000,
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

    my ($retry_captured, $retry_account);
    {
        no warnings qw(redefine once);
        # Leave Registry::DAO::Payment::find REAL so the payment (and its
        # metadata) is reloaded from the DB and round-trips through the
        # jsonb -> ADJUST decode path before _connect_params reads tenant_slug.
        # intent_status must be the terminal decline state: only
        # requires_payment_method / canceled earn a fresh intent, so
        # omitting it would skip the retry branch this subtest exists to
        # cover.
        # The third argument is the caller's settlement, which real
        # process_payment_async runs inside its own transaction; a stub that
        # drops it never reaches the retry branch this subtest covers.
        local *Registry::DAO::Payment::process_payment_async =
            sub ($self, $db, $intent_id, $settle = undef) {
                my $result = {
                    success       => 0,
                    error         => 'Card declined',
                    intent_status => 'requires_payment_method',
                };
                return Mojo::Promise->resolve(
                    $settle ? $settle->($result) : $result);
            };
        local *Registry::Service::Stripe::create_payment_intent_async = sub {
            my ($self, $params) = @_;
            $retry_captured = $params;
            $retry_account  = $self->stripe_account;
            return Mojo::Promise->resolve(
                { id => 'pi_dc_retry', client_secret => 'cs_dc_retry' });
        };
        local $ENV{STRIPE_SECRET_KEY} = 'sk_test_dummy';
        settle($step->handle_payment_callback($tenant_db, $run, {
            payment_intent_id => 'pi_dc_initial',
        }));
    }

    ok $retry_captured, 'retry intent was requested';
    is $retry_account, 'acct_test123',
        'retry intent is created on the same tenant account';
    ok !exists $retry_captured->{'transfer_data[destination]'},
        'retry intent carries no transfer_data[destination]';
    ok !exists $retry_captured->{'on_behalf_of'},
        'retry intent carries no on_behalf_of';
    is $retry_captured->{'application_fee_amount'}, $expected_fee,
        'retry intent carries same application_fee_amount';
};

# ---- (d) async parity: create_payment_intent_async also carries connect params -----
subtest 'async create_payment_intent_async is a direct charge on the tenant account' => sub {
    my $payment = Registry::DAO::Payment->create($tenant_db, {
        user_id  => $parent->id,
        amount_cents => 10000,
        metadata => {
            tenant_slug      => $slug,
            enrollment_items => [],
        },
    });

    my ($async_captured, $async_account);
    {
        no warnings 'redefine';
        local *Registry::Service::Stripe::create_payment_intent_async = sub {
            my ($self, $params) = @_;
            $async_captured = $params;
            $async_account  = $self->stripe_account;
            return Mojo::Promise->resolve({ id => 'pi_async_dest', client_secret => 'cs_async_dest' });
        };
        local $ENV{STRIPE_SECRET_KEY} = 'sk_test_dummy';
        $payment->create_payment_intent_async($tenant_db, { description => 'Async test' })->wait;
    }

    ok $async_captured, 'async stripe client received params';
    is $async_account, 'acct_test123',
        'async: the creating client is bound to the tenant connect account';
    ok !exists $async_captured->{'transfer_data[destination]'},
        'async: no transfer_data[destination]';
    ok !exists $async_captured->{'on_behalf_of'},
        'async: no on_behalf_of';
    is $async_captured->{'application_fee_amount'}, $expected_fee,
        "async: application_fee_amount is $expected_fee cents";
};

# ---- (f) the platform sells like any seller: no slug exemption --------------
subtest 'registry seller is charged directly on its own account' => sub {
    # The platform tenant, given stated 0% terms rather than left on the
    # fallback, with Tamarou's account planted as a fixture.
    give_tenant_terms( $db, 'registry', { rate => 0, name => 'Free' } );
    $db->query(
        'UPDATE registry.tenants SET stripe_connect_account_id = ? WHERE slug = ?',
        'acct_platform123', 'registry',
    );

    my $payment = Registry::DAO::Payment->create($db, {
        user_id      => $admin->id,
        amount_cents => 10000,
        metadata     => { tenant_slug => 'registry', enrollment_items => [] },
    });

    my ($captured, $account);
    {
        no warnings 'redefine';
        local *Registry::Service::Stripe::create_payment_intent = sub {
            my ($self, $params) = @_;
            ($captured, $account) = ($params, $self->stripe_account);
            return { id => 'pi_registry_123', client_secret => 'cs_registry_123' };
        };
        local $ENV{STRIPE_SECRET_KEY} = 'sk_test_dummy';
        $payment->create_payment_intent($db, { description => 'Platform sale' });
    }

    is $account, 'acct_platform123',
        'the registry sale is made on the account its seller row names';
    ok !exists $captured->{'transfer_data[destination]'}, 'no transfer_data[destination]';
    ok !exists $captured->{'on_behalf_of'}, 'no on_behalf_of';
    ok !exists $captured->{'application_fee_amount'},
        'an explicit 0% plan sends no application_fee_amount';
};

# A tenant with its own schema, the stated terms, a parent resident there, and the given account.
my $seller_n = 0;
sub seller_with_account ($account) {
    my $s = 'seller_' . ++$seller_n . "_$$";
    my $a = Registry::DAO::User->create($db, {
        username => "${s}_admin", email => "${s}_admin\@test.example",
        name => 'Seller Admin', user_type => 'admin',
    });
    Registry::DAO::Tenant->provision($db, { name => "Seller $s", slug => $s, users => [ $a ] });
    $db->query('UPDATE registry.tenants SET stripe_connect_account_id = ? WHERE slug = ?',
        $account, $s);
    give_tenant_terms( $db, $s, { rate => $stated_rate } );
    my $sdb = Registry::DAO->new(url => $test_db->uri, schema => $s)->db;
    my $p = Registry::DAO::User->create($sdb, {
        username => "${s}_parent", email => "${s}_parent\@test.example",
        name => 'Seller Parent', user_type => 'parent',
    });
    return ($s, $sdb, $p);
}

subtest 'seller without connect account is refused before stripe' => sub {
    for my $case ( [ 'NULL', undef ], [ 'empty', '' ] ) {
        my ($label, $account) = @$case;
        my ($s, $sdb, $p) = seller_with_account($account);
        my $payment = Registry::DAO::Payment->create($sdb, {
            user_id => $p->id, amount_cents => 10000,
            metadata => { tenant_slug => $s, enrollment_items => [] },
        });

        my $requests = 0;
        no warnings 'redefine';
        local *Registry::Service::Stripe::_request_async = sub {
            $requests++;
            return Mojo::Promise->resolve({ id => 'pi_never', client_secret => 'cs_never' });
        };
        local $ENV{STRIPE_SECRET_KEY} = 'sk_test_dummy';

        my $ok = eval { $payment->create_payment_intent($sdb, {}); 1 };
        ok !$ok, "$label account: the sync charge is refused";
        like $@, qr/no seller Stripe account/, "$label account: refused for the missing account";

        my $async_error;
        $payment->create_payment_intent_async($sdb, {})
            ->catch(sub ($e) { $async_error = $e })->wait;
        like $async_error, qr/no seller Stripe account/,
            "$label account: the async charge is refused for the missing account";

        is $requests, 0, "$label account: no request reached Stripe";
    }
};

subtest 'no params carry transfer data or on_behalf_of' => sub {
    my @sent;
    no warnings 'redefine';
    local *Registry::Service::Stripe::create_customer = sub { { id => 'cus_np' } };
    local *Registry::Service::Stripe::create_customer_async = sub {
        Mojo::Promise->resolve({ id => 'cus_np' });
    };
    local *Registry::Service::Stripe::create_payment_intent = sub {
        push @sent, $_[1]; { id => 'pi_np', client_secret => 'cs_np' };
    };
    local *Registry::Service::Stripe::create_payment_intent_async = sub {
        push @sent, $_[1]; Mojo::Promise->resolve({ id => 'pi_np', client_secret => 'cs_np' });
    };
    local $ENV{STRIPE_SECRET_KEY} = 'sk_test_dummy';

    for my $instalment ( 0, 1 ) {
        for my $async ( 0, 1 ) {
            my $payment = Registry::DAO::Payment->create($tenant_db, {
                user_id => $parent->id, amount_cents => 10000,
                ( $instalment ? ( instalment_seq => 1, instalment_count => 3 ) : () ),
                metadata => { tenant_slug => $slug, enrollment_items => [] },
            });
            $async ? $payment->create_payment_intent_async($tenant_db, {})->wait
                   : $payment->create_payment_intent($tenant_db, {});
        }
    }

    is scalar @sent, 4, 'one-off and instalment-first, sync and async, all sent';
    my @leaks = grep { /\Atransfer_data\[|\Aon_behalf_of\z/ } map { keys %$_ } @sent;
    is_deeply \@leaks, [], 'no transfer_data[...] key and no on_behalf_of on any path';
};

subtest 'retry after account change reuses first account and key' => sub {
    my ($s, $sdb, $p) = seller_with_account('acct_first');
    my $payment = Registry::DAO::Payment->create($sdb, {
        user_id => $p->id, amount_cents => 10000,
        metadata => { tenant_slug => $s, enrollment_items => [] },
    });

    my @calls;
    no warnings 'redefine';
    local *Registry::Service::Stripe::create_payment_intent = sub {
        push @calls, [ $_[0]->stripe_account, $_[1]{_idempotency_key} ];
        return { id => 'pi_retry_same', client_secret => 'cs_retry_same' };
    };
    local $ENV{STRIPE_SECRET_KEY} = 'sk_test_dummy';

    $payment->create_payment_intent($sdb, {});
    $db->query('UPDATE registry.tenants SET stripe_connect_account_id = ? WHERE slug = ?',
        'acct_second', $s);
    Registry::DAO::Payment->find($sdb, { id => $payment->id })
        ->create_payment_intent($sdb, {});

    is $calls[0][0], 'acct_first', 'the first create is on the first account';
    is $calls[1][0], 'acct_first', 'the retry is still on the first-resolved account';
    is $calls[1][1], $calls[0][1], 'and replays the same idempotency key';
};

$test_db->cleanup_test_database;
done_testing;
