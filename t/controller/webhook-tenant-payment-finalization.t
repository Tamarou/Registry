# ABOUTME: Tests that payment_intent.succeeded completes a session checkout in the correct tenant schema.
# ABOUTME: Also tests account.updated mirroring of Stripe Connect readiness flags.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::MockObject;
use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::FamilyMember;
use Registry::DAO::Payment;
use Registry::Controller::Webhooks;
use Test::Registry::DB;
use Test::Registry::PricingProbe qw( state_platform_terms );
use Test::Registry::Mojo;
use Test::Registry::StripeWebhook;
use Test::Registry::Fixtures;
use Test::Registry::Sessions qw( make_session session_offer held_cart );
use Test::Registry::SessionCheckout qw( started_charge drive );

local $ENV{STRIPE_SECRET_KEY}     = 'sk_test_webhook_tenant_test';
local $ENV{STRIPE_WEBHOOK_SECRET} = 'whsec_test_webhook_tenant_test';
local $ENV{STRIPE_CONNECT_WEBHOOK_SECRET} = 'whsec_test_webhook_tenant_connect';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

# ---------------------------------------------------------------------------
# Provision a tenant and create fixtures entirely within the tenant schema.
# ---------------------------------------------------------------------------

my $slug = 'wh_tenant_' . $$;

my $admin = Registry::DAO::User->create($db, {
    username  => "wh_admin_$$",
    email     => "wh_admin_$$\@test.example",
    name      => 'WH Admin',
    user_type => 'admin',
});

my $tenant = Registry::DAO::Tenant->provision($db, {
    name  => "WH Tenant $$",
    slug  => $slug,
    users => [ $admin ],
    stripe_connect_account_id => 'acct_wh_test',
    stripe_charges_enabled    => 0,
    stripe_details_submitted  => 0,
});
ok $tenant, 'tenant provisioned';
state_platform_terms( $db, $slug, { rate => 0 } );

# Tenant-schema DAO / db handle
my $tdao = Registry::DAO->new(url => $ENV{DB_URL}, schema => $slug);
my $tdb  = $tdao->db;

# A parent and child who live only in the tenant schema, a session on sale
# there, and the child's seat held and charged: the cart's one payment.
my $parent = Registry::DAO::User->create($tdb, {
    username  => "wh_parent_$$",
    email     => "wh_parent_$$\@test.example",
    name      => 'WH Parent',
    user_type => 'parent',
});
my $child = Registry::DAO::FamilyMember->create($tdb,
    { family_id => $parent->id, child_name => 'WH Kid', birth_date => '2018-01-01' });
my $session = make_session($tdb);
my $version = session_offer($tdb, $session, price_cents => 15000);

# The readiness the payment step needs, set for the charge and put back for
# the account.updated subtests below, which flip it themselves.
$db->query(q{UPDATE registry.tenants SET stripe_charges_enabled = TRUE, stripe_details_submitted = TRUE
              WHERE slug = ?}, $slug);
my ( $run, $pay ) = held_cart($tdao, $parent->id, [ $child->id, $session->id, $version->id, 'pay' ]);
my $tenant_payment = started_charge($tdb, $run, $pay);
$db->query(q{UPDATE registry.tenants SET stripe_charges_enabled = FALSE, stripe_details_submitted = FALSE
              WHERE slug = ?}, $slug);
ok $tenant_payment, 'tenant payment created in tenant schema';

# Verify payment is NOT visible via the registry-schema connection.
my $in_registry = $db->select('registry.payments', ['id'], { id => $tenant_payment->id })->hash;
ok !$in_registry, 'tenant payment not visible in registry schema (pre-condition)';

# ---------------------------------------------------------------------------
# Build a webhook controller backed by a mock app pointing at our test DAO.
# ---------------------------------------------------------------------------

my $mock_log = Test::MockObject->new;
$mock_log->set_always('error', undef);
$mock_log->set_always('warn',  undef);
$mock_log->set_always('debug', undef);
my @log_messages;
$mock_log->mock('info', sub { push @log_messages, $_[1] });

my $mock_app = Test::MockObject->new;
$mock_app->mock('dao', sub { $dao });
$mock_app->mock('log', sub { $mock_log });

my $wh = Registry::Controller::Webhooks->new;
$wh->{app} = $mock_app;

# Tenant routing lives in the Connect action, not in the handlers: it resolves
# the tenant from event.account and sets a transaction-local search_path that
# the handlers inherit. So the routing subtest has to go through the real
# action -- calling a handler directly would hand it a pre-scoped handle and
# assert nothing about which schema it picked.
my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub ($c, $tenant = undef) {
    defined $tenant ? Registry::DAO->new(url => $test_db->uri, schema => $tenant) : $dao });

# ---------------------------------------------------------------------------
# Helper: count entitlements and notifications for a given payment (in tenant).
# ---------------------------------------------------------------------------

sub tenant_entitlement_count {
    scalar @{ $tdb->select('entitlements', '*', { payment_id => $tenant_payment->id })->hashes };
}

sub tenant_confirmation_count {
    scalar @{ $tdb->select('notifications', '*',
        { user_id => $parent->id, type => 'enrollment_confirmation' })->hashes };
}

# ---------------------------------------------------------------------------
# Subtest 1: tenant completion -- payment found in tenant schema, entitlement
# created there, NOT visible in registry.
# ---------------------------------------------------------------------------

subtest 'connect succeeded event completes the checkout in account tenant' => sub {
    my $evt = {
        id      => 'evt_tenant_test_1',
        type    => 'payment_intent.succeeded',
        account => 'acct_wh_test',
        data    => { object => {
            id       => $tenant_payment->stripe_payment_intent_id,
            metadata => {
                payment_id  => $tenant_payment->id,
                tenant_slug => $slug,
            },
        } },
    };

    # Driven through the real action: it resolves event.account against
    # registry.tenants, opens one transaction, and sets a transaction-local
    # search_path, so the settlement -- payment lookup and completed write --
    # lands in the tenant schema on one connection; the run's driver it
    # queues books the child there too.
    Test::Registry::StripeWebhook::post_connect($t, $evt)->status_is(200);
    drive($t->app->minion);

    is tenant_entitlement_count(), 1, 'entitlement created in tenant schema';
    is tenant_confirmation_count(), 1, 'confirmation queued in tenant schema';

    my $refreshed = Registry::DAO::Payment->find($tdb, { id => $tenant_payment->id });
    is $refreshed->status, 'completed', 'payment marked completed in tenant schema';

    # Registry schema must NOT have any entitlement for this payment.
    my $reg_ent = $db->select('registry.entitlements', ['id'],
        { payment_id => $tenant_payment->id })->hash;
    ok !$reg_ent, 'entitlement NOT created in registry schema';
};

# ---------------------------------------------------------------------------
# Subtest 2: a payment this schema has no row for -- logged and ignored, since
# a retry cannot create the row.
# ---------------------------------------------------------------------------

subtest 'missing payment is logged and ignored' => sub {
    my $bad_id = '00000000-0000-0000-0000-000000000000';
    my $evt = {
        type => 'payment_intent.succeeded',
        data => { object => {
            id       => 'pi_tenant_bad_1',
            metadata => { payment_id => $bad_id },
        } },
    };

    @log_messages = ();
    my $returned = eval { $wh->_process_payment_intent_succeeded($db, $evt); 1 };
    ok $returned, 'handler returns without dying';
    ok scalar(grep { /\Q$bad_id\E.*not found/ } @log_messages), 'the missing payment is logged';
};

# ---------------------------------------------------------------------------
# Subtest 3: no payment_id in metadata -- silent ignore, no die.
# ---------------------------------------------------------------------------

subtest 'event without payment_id is silently ignored' => sub {
    my $evt = {
        type => 'payment_intent.succeeded',
        data => { object => {
            id       => 'pi_no_meta',
            metadata => {},   # no payment_id key
        } },
    };

    my $died = 0;
    eval {
        $wh->_process_payment_intent_succeeded($db, $evt);
    };
    $died = 1 if $@;
    ok !$died, 'no payment_id event returns without dying';
    is tenant_entitlement_count(), 1, 'no extra entitlement created (still 1 from earlier)';
};

# ---------------------------------------------------------------------------
# Subtest 4: account.updated mirrors Stripe Connect readiness flags.
# ---------------------------------------------------------------------------

subtest 'account.updated syncs charges_enabled/details_submitted to tenant' => sub {
    my $evt_known = {
        type => 'account.updated',
        data => { object => {
            id                => 'acct_wh_test',
            charges_enabled   => 1,
            details_submitted => 1,
        } },
    };

    @log_messages = ();
    $wh->_process_account_updated($db, $evt_known);

    my $row = $db->select('registry.tenants', ['stripe_charges_enabled', 'stripe_details_submitted'],
        { stripe_connect_account_id => 'acct_wh_test' })->hash;
    ok $row, 'tenant row found after account.updated';
    is $row->{stripe_charges_enabled},   1, 'charges_enabled mirrored to 1';
    is $row->{stripe_details_submitted}, 1, 'details_submitted mirrored to 1';

    # Flip off
    my $evt_off = {
        type => 'account.updated',
        data => { object => {
            id                => 'acct_wh_test',
            charges_enabled   => 0,
            details_submitted => 1,
        } },
    };
    $wh->_process_account_updated($db, $evt_off);

    my $row2 = $db->select('registry.tenants', ['stripe_charges_enabled', 'stripe_details_submitted'],
        { stripe_connect_account_id => 'acct_wh_test' })->hash;
    is $row2->{stripe_charges_enabled},   0, 'charges_enabled mirrored back to 0';
    is $row2->{stripe_details_submitted}, 1, 'details_submitted preserved on the off-flip';
};

subtest 'account.updated with unknown account logs but does not die' => sub {
    my $evt = {
        type => 'account.updated',
        data => { object => {
            id                => 'acct_unknown_xyz',
            charges_enabled   => 1,
            details_submitted => 1,
        } },
    };

    @log_messages = ();
    my $died = 0;
    eval { $wh->_process_account_updated($db, $evt) };
    $died = 1 if $@;
    ok !$died, 'unknown acct_id does not die';
    ok scalar(grep { /unknown connected account/i } @log_messages),
        'unknown account logged via app->log->info';
};

# ---------------------------------------------------------------------------
# Subtest 5: a registry-schema cart (the platform selling its own sessions)
# still completes on the registry connection.
# ---------------------------------------------------------------------------

subtest 'registry-schema cart payment completes on registry connection' => sub {
    my $seller = Test::Registry::Fixtures::platform_seller($db);
    $db->query(q{UPDATE registry.tenants SET stripe_charges_enabled = TRUE, stripe_details_submitted = TRUE
                  WHERE slug = ?}, $seller);
    state_platform_terms( $db, $seller, { rate => 0 } );
    my $reg_parent = Registry::DAO::User->create($db, {
        username  => "reg_parent_wh_$$",
        email     => "reg_parent_wh_$$\@test.example",
        name      => 'Reg Parent WH',
        user_type => 'parent',
    });
    my $reg_child = Registry::DAO::FamilyMember->create($db,
        { family_id => $reg_parent->id, child_name => 'Reg Kid WH', birth_date => '2018-01-01' });
    my $reg_session = make_session($db);
    my $reg_version = session_offer($db, $reg_session, price_cents => 7500);
    my ( $reg_run, $reg_pay ) = held_cart($dao, $reg_parent->id,
        [ $reg_child->id, $reg_session->id, $reg_version->id, 'pay' ]);
    my $reg_payment = started_charge($db, $reg_run, $reg_pay);
    ok $reg_payment, 'registry-schema payment created';

    Test::Registry::SessionCheckout::post_succeeded($t, $reg_payment, 'acct_platform_test')->status_is(200);
    drive($t->app->minion);

    is $db->select('registry.entitlements', ['id'], { payment_id => $reg_payment->id })->rows, 1,
        'entitlement created in registry schema for registry payment';
    is Registry::DAO::Payment->find($db, { id => $reg_payment->id })->status, 'completed',
        'registry payment marked completed';
};

done_testing;
