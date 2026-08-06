# ABOUTME: Tests F-3 -- subscription webhook events are classified and routed correctly.
# ABOUTME: Verifies customer.subscription.updated/deleted reach installment handlers.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::MockObject;
use Registry::DAO;
use Registry::DAO::PricingPlan;
use Registry::DAO::PaymentSchedule;
use Registry::Controller::Webhooks;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

# Stripe env required so modules that load Stripe client don't die
local $ENV{STRIPE_SECRET_KEY} = 'sk_test_routing_test';

# ---------------------------------------------------------------------------
# Fixtures: insert a payment_schedule tied to a known Stripe subscription ID.
# ---------------------------------------------------------------------------

my $parent_user = $dao->create( User => {
    username  => 'routing_parent',
    name      => 'Routing Parent',
    user_type => 'parent',
    email     => 'routing_p@test.local',
} );

my $loc = $dao->create( Location => {
    name         => 'Routing Studio',
    slug         => 'routing-studio',
    address_info => {},
    metadata     => {},
} );

my $prog = $dao->create( Project => {
    name              => 'Routing Camp',
    status            => 'published',
    program_type_slug => 'summer-camp',
    metadata          => {},
} );

my $teacher = $dao->create( User => {
    username  => 'routing_teacher',
    name      => 'Routing Teacher',
    user_type => 'staff',
    email     => 'routing_t@test.local',
} );

my $session = $dao->create( Session => {
    name       => 'Routing Session',
    start_date => '2026-07-01',
    end_date   => '2026-07-31',
    status     => 'published',
    capacity   => 10,
    metadata   => {},
} );

my $event = $dao->create( Event => {
    time        => '2026-07-01 10:00:00',
    duration    => 60,
    location_id => $loc->id,
    project_id  => $prog->id,
    teacher_id  => $teacher->id,
    capacity    => 10,
    metadata    => {},
} );
$session->add_events( $db, $event->id );

# Direct DB insert for enrollment (schema-qualified)
my $enrollment_id = $db->insert( 'registry.enrollments', {
    session_id   => $session->id,
    student_id   => $parent_user->id,
    parent_id    => $parent_user->id,
    status       => 'active',
    metadata     => '{}',
}, { returning => 'id' } )->hash->{id};

# Create a pricing_plan to satisfy the FK
my $plan = Registry::DAO::PricingPlan->create( $db, {
    session_id           => $session->id,
    plan_name            => 'Routing Plan',
    plan_type            => 'standard',
    amount_cents         => 30000,
    installments_allowed => 1,
    installment_count    => 3,
} );

my $SUB_ID = 'sub_routing_f3_test';

my $schedule = Registry::DAO::PaymentSchedule->create( $db, {
    enrollment_id          => $enrollment_id,
    pricing_plan_id        => $plan->id,
    stripe_subscription_id => $SUB_ID,
    total_amount           => 300.00,
    installment_amount     => 100.00,
    installment_count      => 3,
    status                 => 'active',
} );
ok $schedule, 'payment_schedule fixture created';

# ---------------------------------------------------------------------------
# Webhook controller with a mock app pointing at our test DAO.
# Following the pattern used in t/integration/installment-webhook-processing.t.
# ---------------------------------------------------------------------------

my $mock_app = Test::MockObject->new;
$mock_app->mock( 'dao', sub { $dao } );
$mock_app->mock( 'log', sub {
    my $log = Test::MockObject->new;
    $log->set_always( 'info',  undef );
    $log->set_always( 'error', undef );
    $log->set_always( 'warn',  undef );
    $log->set_always( 'debug', undef );
    return $log;
});

my $wh = Registry::Controller::Webhooks->new;
$wh->{app} = $mock_app;

# ---------------------------------------------------------------------------
# Subtest 1: customer.subscription.updated WITH a matching payment_schedule
# must be classified as an installment event.
# Under the broken regex (/.subscription\.$/) this returns 0.
# ---------------------------------------------------------------------------

subtest 'customer.subscription.updated with payment_schedule classified as installment' => sub {
    my $evt = {
        type => 'customer.subscription.updated',
        data => {
            object => {
                id     => $SUB_ID,
                status => 'active',
            },
        },
    };

    my $result = $wh->_is_installment_payment_event($evt);
    ok $result,
        'customer.subscription.updated with matching payment_schedule is an installment event';
};

# ---------------------------------------------------------------------------
# Subtest 2: customer.subscription.deleted WITH a matching payment_schedule
# must also be classified as an installment event.
# ---------------------------------------------------------------------------

subtest 'customer.subscription.deleted with payment_schedule classified as installment' => sub {
    my $evt = {
        type => 'customer.subscription.deleted',
        data => {
            object => {
                id     => $SUB_ID,
                status => 'canceled',
            },
        },
    };

    my $result = $wh->_is_installment_payment_event($evt);
    ok $result,
        'customer.subscription.deleted with matching payment_schedule is an installment event';
};

# ---------------------------------------------------------------------------
# Subtest 3: customer.subscription.updated with NO payment_schedule must NOT
# be classified as installment (platform subscription safety check).
# ---------------------------------------------------------------------------

subtest 'customer.subscription.updated without payment_schedule is not installment' => sub {
    my $evt = {
        type => 'customer.subscription.updated',
        data => {
            object => {
                id     => 'sub_platform_no_schedule',
                status => 'active',
            },
        },
    };

    my $result = $wh->_is_installment_payment_event($evt);
    ok !$result,
        'customer.subscription.updated without payment_schedule is not an installment event';
};

# ---------------------------------------------------------------------------
# Subtest 4: invoice.paid still classified as installment (regression guard).
# ---------------------------------------------------------------------------

subtest 'invoice.paid with matching subscription still classified as installment' => sub {
    my $evt = {
        type => 'invoice.paid',
        data => {
            object => {
                id           => 'in_routing_test',
                subscription => $SUB_ID,
                status       => 'paid',
            },
        },
    };

    my $result = $wh->_is_installment_payment_event($evt);
    ok $result,
        'invoice.paid with matching subscription still classified as installment event';
};

# ---------------------------------------------------------------------------
# Subtest 5: _handle_installment_subscription_updated updates schedule status.
# Verifies the handler is reachable and functional once the routing fix allows
# the event to reach it.
# ---------------------------------------------------------------------------

subtest '_handle_installment_subscription_updated updates payment schedule status' => sub {
    $wh->_handle_installment_subscription_updated( $db, {
        id     => $SUB_ID,
        status => 'past_due',
    });

    my $refreshed = Registry::DAO::PaymentSchedule->find( $db, { id => $schedule->id } );
    is $refreshed->status, 'past_due',
        'schedule status updated to past_due by the subscription updated handler';
};

done_testing;
