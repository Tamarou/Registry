# ABOUTME: Tests that payment_intent.succeeded finalizes payments in the correct tenant schema.
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
use Registry::DAO::Family;
use Registry::DAO::Payment;
use Registry::Controller::Webhooks;
use Test::Registry::DB;
use Test::Registry::Mojo;
use Digest::SHA qw(hmac_sha256_hex);
use Mojo::JSON qw(encode_json);

local $ENV{STRIPE_SECRET_KEY}     = 'sk_test_webhook_tenant_test';
local $ENV{STRIPE_WEBHOOK_SECRET} = 'whsec_test_webhook_tenant_test';

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

# Tenant-schema DAO / db handle
my $tdao = Registry::DAO->new(url => $ENV{DB_URL}, schema => $slug);
my $tdb  = $tdao->db;

# Create a parent + child that live only in the tenant schema.
my $parent = Registry::DAO::User->create($tdb, {
    username  => "wh_parent_$$",
    email     => "wh_parent_$$\@test.example",
    name      => 'WH Parent',
    user_type => 'parent',
});
my $child = Registry::DAO::Family->add_child($tdb, $parent->id, {
    child_name        => 'WH Kid',
    birth_date        => '2018-01-01',
    grade             => '3',
    medical_info      => {},
    emergency_contact => { name => 'Emerg', phone => '555-0100' },
});

# Session/event fixtures in the tenant schema.
my $loc = Registry::DAO::Location->create($tdb, {
    name         => "WH Studio $$",
    slug         => "wh_studio_$$",
    address_info => {},
    metadata     => {},
});
my $prog = Registry::DAO::Project->create($tdb, {
    name              => "WH Camp $$",
    status            => 'published',
    program_type_slug => 'summer-camp',
    metadata          => {},
});
my $teacher = Registry::DAO::User->create($tdb, {
    username  => "wh_teacher_$$",
    email     => "wh_teacher_$$\@test.example",
    name      => 'WH Teacher',
    user_type => 'staff',
});
my $session = Registry::DAO::Session->create($tdb, {
    name       => "WH Week $$",
    start_date => '2026-07-01',
    end_date   => '2026-07-31',
    status     => 'published',
    capacity   => 10,
    metadata   => {},
});
my $event = Registry::DAO::Event->create($tdb, {
    time        => '2026-07-01 10:00:00',
    duration    => 60,
    location_id => $loc->id,
    project_id  => $prog->id,
    teacher_id  => $teacher->id,
    capacity    => 10,
    metadata    => {},
});
$session->add_events($tdb, $event->id);

# Create the tenant payment with enrollment_items and tenant_slug metadata.
my $tenant_payment = Registry::DAO::Payment->create($tdb, {
    user_id  => $parent->id,
    amount_cents => 15000,
    status   => 'pending',
    metadata => {
        enrollment_items => [ { session_id => $session->id, child_id => $child->id } ],
        tenant_slug      => $slug,
    },
});
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

# Tenant routing lives in stripe(), not in the handlers: stripe() resolves the
# slug, validates it against registry.tenants, and sets a transaction-local
# search_path that the handlers inherit. So the routing subtest has to go
# through the real action -- calling a handler directly would hand it a
# pre-scoped handle and assert nothing about which schema it picked.
my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $dao });

sub post_webhook ($event) {
    my $payload   = encode_json($event);
    my $timestamp = time();
    my $sig       = hmac_sha256_hex("$timestamp.$payload", $ENV{STRIPE_WEBHOOK_SECRET});
    my $tx = $t->ua->post('/webhooks/stripe' => {
        'stripe-signature' => "t=$timestamp,v1=$sig",
        'Content-Type'     => 'application/json',
    } => $payload);
    return $t->tx($tx);
}

# ---------------------------------------------------------------------------
# Helper: count enrollments and notifications for a given payment (in tenant).
# ---------------------------------------------------------------------------

sub tenant_enrollment_count {
    scalar @{ $tdb->select('enrollments', '*', { payment_id => $tenant_payment->id })->hashes };
}

sub tenant_confirmation_count {
    scalar @{ $tdb->select('notifications', '*',
        { user_id => $parent->id, type => 'enrollment_confirmation' })->hashes };
}

# ---------------------------------------------------------------------------
# Subtest 1: tenant finalization -- payment found in tenant schema, enrollment
# created there, NOT visible in registry.
# ---------------------------------------------------------------------------

subtest 'tenant payment finalized in tenant schema' => sub {
    my $evt = {
        id   => 'evt_tenant_test_1',
        type => 'payment_intent.succeeded',
        data => { object => {
            id       => 'pi_tenant_test_1',
            metadata => {
                payment_id  => $tenant_payment->id,
                tenant_slug => $slug,
            },
        } },
    };

    # Driven through the real action: stripe() resolves the slug against
    # registry.tenants, opens one transaction, and sets a transaction-local
    # search_path, so the whole settlement -- payment lookup, completed write,
    # enrollment, notification -- lands in the tenant schema on one connection.
    post_webhook($evt)->status_is(200);

    is tenant_enrollment_count(), 1, 'enrollment created in tenant schema';
    is tenant_confirmation_count(), 1, 'confirmation queued in tenant schema';

    my $refreshed = Registry::DAO::Payment->find($tdb, { id => $tenant_payment->id });
    is $refreshed->status, 'completed', 'payment marked completed in tenant schema';

    # Registry schema must NOT have any enrollment row for this payment.
    my $reg_enr = $db->select('registry.enrollments', ['id'],
        { payment_id => $tenant_payment->id })->hash;
    ok !$reg_enr, 'enrollment NOT created in registry schema';
};

# ---------------------------------------------------------------------------
# Subtest 2: missing payment_id -- die with not-found message (Stripe retries).
# ---------------------------------------------------------------------------

subtest 'missing payment dies with not-found message' => sub {
    my $bad_id = '00000000-0000-0000-0000-000000000000';
    my $evt = {
        type => 'payment_intent.succeeded',
        data => { object => {
            id       => 'pi_tenant_bad_1',
            metadata => {
                payment_id  => $bad_id,
                tenant_slug => $slug,
            },
        } },
    };

    my $died = 0;
    my $msg  = '';
    eval {
        $wh->_process_payment_intent_succeeded($db, $evt);
    };
    if ($@) {
        $died = 1;
        $msg  = $@;
    }
    ok $died, 'handler dies when payment not found';
    like $msg, qr/payment.*not found/i, 'die message mentions payment not found';
    like $msg, qr/\Q$slug\E/, 'die message includes tenant slug';
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
    is tenant_enrollment_count(), 1, 'no extra enrollment created (still 1 from earlier)';
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
# Subtest 5: registry-schema payment (no tenant_slug) still finalizes on the
# registry connection (regression guard -- mirrors payment-intent-webhook.t).
# ---------------------------------------------------------------------------

subtest 'registry-schema payment without tenant_slug finalizes on registry connection' => sub {
    my $reg_parent = Registry::DAO::User->create($db, {
        username  => "reg_parent_wh_$$",
        email     => "reg_parent_wh_$$\@test.example",
        name      => 'Reg Parent WH',
        user_type => 'parent',
    });
    my $reg_child = Registry::DAO::Family->add_child($db, $reg_parent->id, {
        child_name        => 'Reg Kid WH',
        birth_date        => '2018-01-01',
        grade             => '3',
        medical_info      => {},
        emergency_contact => { name => 'Emerg2', phone => '555-0101' },
    });

    # Build session fixtures in the registry schema.
    my $reg_loc = Registry::DAO::Location->create($db, {
        name         => "Reg WH Studio $$",
        slug         => "reg_wh_studio_$$",
        address_info => {},
        metadata     => {},
    });
    my $reg_prog = Registry::DAO::Project->create($db, {
        name              => "Reg WH Camp $$",
        status            => 'published',
        program_type_slug => 'summer-camp',
        metadata          => {},
    });
    my $reg_teacher = Registry::DAO::User->create($db, {
        username  => "reg_wh_teacher_$$",
        email     => "reg_wh_teacher_$$\@test.example",
        name      => 'Reg WH Teacher',
        user_type => 'staff',
    });
    my $reg_session = Registry::DAO::Session->create($db, {
        name       => "Reg WH Week $$",
        start_date => '2026-08-01',
        end_date   => '2026-08-31',
        status     => 'published',
        capacity   => 10,
        metadata   => {},
    });
    my $reg_event = Registry::DAO::Event->create($db, {
        time        => '2026-08-01 10:00:00',
        duration    => 60,
        location_id => $reg_loc->id,
        project_id  => $reg_prog->id,
        teacher_id  => $reg_teacher->id,
        capacity    => 10,
        metadata    => {},
    });
    $reg_session->add_events($db, $reg_event->id);

    my $reg_payment = Registry::DAO::Payment->create($db, {
        user_id  => $reg_parent->id,
        amount_cents => 7500,
        status   => 'pending',
        metadata => {
            enrollment_items => [ { session_id => $reg_session->id, child_id => $reg_child->id } ],
            tenant_slug      => undef,
        },
    });
    ok $reg_payment, 'registry-schema payment created';

    my $evt = {
        type => 'payment_intent.succeeded',
        data => { object => {
            id       => 'pi_reg_schema_wh_1',
            metadata => { payment_id => $reg_payment->id },
            # no tenant_slug key in metadata
        } },
    };

    $wh->_process_payment_intent_succeeded($db, $evt);

    my $enr_count = scalar @{ $db->select('registry.enrollments', '*',
        { payment_id => $reg_payment->id })->hashes };
    is $enr_count, 1, 'enrollment created in registry schema for registry payment';

    my $refreshed = Registry::DAO::Payment->find($db, { id => $reg_payment->id });
    is $refreshed->status, 'completed', 'registry payment marked completed';
};

done_testing;
