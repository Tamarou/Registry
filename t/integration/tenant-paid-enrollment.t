# ABOUTME: End-to-end integration test for tenant-scoped paid enrollment.
# ABOUTME: Strings together Stripe Connect readiness gate, payment intent creation, webhook finalization, and idempotency.
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
use Registry::DAO::Session;
use Registry::DAO::PricingPlan;
use Registry::DAO::Project;
use Registry::DAO::Event;
use Registry::DAO::Location;
use Registry::DAO::Payment;
use Registry::DAO::WorkflowSteps::Payment;
use Test::Registry::Async qw( settle );
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::Controller::Webhooks;
use Registry::Service::Stripe;
use Test::Registry::DB;
use Mojo::Promise;

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_dummy';

# ---------------------------------------------------------------------------
# 1. Provision a fresh tenant and build all fixtures in the tenant schema.
# ---------------------------------------------------------------------------

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $slug = 'e2e_paid_' . $$;

my $admin = Registry::DAO::User->create($db, {
    username  => "e2e_admin_$$",
    email     => "e2e_admin_$$\@test.example",
    name      => 'E2E Admin',
    user_type => 'admin',
});

my $tenant = Registry::DAO::Tenant->provision($db, {
    name  => "E2E Paid Tenant $$",
    slug  => $slug,
    users => [ $admin ],
});
ok $tenant, 'tenant provisioned';

# Tenant-schema connection
my $tdao = Registry::DAO->new(url => $test_db->uri, schema => $slug);
my $tdb  = $tdao->db;

# --- fixtures in the tenant schema ---

my $location = Registry::DAO::Location->create($tdb, {
    name         => 'E2E Studio',
    address_info => { street_address => '1 E2E Blvd', city => 'T', state => 'TX', postal_code => '78701' },
    metadata     => {},
});

my $teacher = Registry::DAO::User->create($tdb, {
    name      => 'E2E Teacher',
    username  => "e2e_teacher_$$",
    email     => "e2e_teacher_$$\@test.com",
    user_type => 'staff',
});

my $project = Registry::DAO::Project->create($tdb, {
    name              => 'E2E Summer Camp',
    slug              => "e2e_camp_$$",
    status            => 'published',
    program_type_slug => 'summer-camp',
    metadata          => {},
});

my $event = Registry::DAO::Event->create($tdb, {
    time        => '2026-07-01 10:00:00',
    duration    => 120,
    location_id => $location->id,
    project_id  => $project->id,
    teacher_id  => $teacher->id,
    capacity    => 20,
    metadata    => {},
});

# $150 paid session
my $session = Registry::DAO::Session->create($tdb, {
    name       => 'E2E Week',
    start_date => '2026-07-01',
    end_date   => '2026-07-07',
    status     => 'published',
    capacity   => 20,
    metadata   => {},
});
$session->add_events($tdb, $event->id);
my $PLAN_AMOUNT_CENTS = 15_000;
Registry::DAO::PricingPlan->create($tdb, {
    session_id => $session->id,
    plan_name  => 'Standard',
    plan_type  => 'standard',
    amount_cents => $PLAN_AMOUNT_CENTS,
});

# Parent + child in the tenant schema
my $parent = Registry::DAO::User->create($tdb, {
    email     => "e2e_parent_$$\@example.com",
    username  => "e2e_parent_$$",
    name      => 'E2E Parent',
    user_type => 'parent',
});

my $child = Registry::DAO::Family->add_child($tdb, $parent->id, {
    child_name        => 'E2E Child',
    birth_date        => '2018-03-15',
    grade             => '3',
    medical_info      => {},
    emergency_contact => { name => 'Emergency', phone => '555-0199' },
});

# Minimal workflow + payment step in tenant schema
my $workflow = Registry::DAO::Workflow->create($tdb, {
    name        => 'E2E Test Workflow',
    slug        => "e2e-workflow-$$",
    description => 'End-to-end paid enrollment test workflow',
});

my $payment_step_row = Registry::DAO::WorkflowStep->create($tdb, {
    workflow_id => $workflow->id,
    slug        => 'payment',
    class       => 'Registry::DAO::WorkflowSteps::Payment',
    description => 'Payment processing step',
});

Registry::DAO::WorkflowStep->create($tdb, {
    workflow_id => $workflow->id,
    slug        => 'complete',
    class       => 'Registry::DAO::WorkflowStep',
    description => 'Completion step',
    depends_on  => $payment_step_row->id,
});

$workflow->update($tdb, { first_step => 'payment' }, { id => $workflow->id });

# Helper: build a paid workflow run seeded with all required data
sub make_e2e_run {
    my $run = $workflow->new_run($tdb);
    $run->update_data($tdb, {
        user_id            => $parent->id,
        children           => [ {
            id         => $child->id,
            first_name => 'E2E',
            last_name  => 'Child',
            birth_date => '2018-03-15',
            grade      => '3',
        } ],
        session_selections => { $child->id => $session->id },
        enrollment_items   => [ { child_id => $child->id, session_id => $session->id } ],
        __tenant_slug      => $slug,
    });
    return $run;
}

# Helper: fetch payment step object fresh from DB
sub get_payment_step {
    return $workflow->get_step($tdb, { slug => 'payment' });
}

# ---------------------------------------------------------------------------
# 2. Gate refusal: tenant NOT ready -> create_payment returns error, zero payments.
# ---------------------------------------------------------------------------

subtest 'gate refusal: unready tenant blocks paid enrollment' => sub {
    ok !$tenant->stripe_connect_ready,
        'precondition: tenant stripe_connect_ready is false';

    my $run    = make_e2e_run();
    my $step   = get_payment_step();
    my $result = settle($step->process($tdb, { agreeTerms => 1 }, $run));

    ok $result->{errors}, 'gate returned errors';
    like $result->{errors}[0], qr/not yet available/i,
        'friendly error message mentions unavailability';
    is $result->{next_step}, $step->id, 'stays on payment step (not advanced)';

    # Zero payment rows in both tenant and registry schemas
    my $tenant_count = $tdb->select('payments', ['id'], { user_id => $parent->id })->hashes->size;
    is $tenant_count, 0, 'no payment row in tenant schema when gate fires';

    my $registry_count = $db->select('registry.payments', ['id'], { user_id => $parent->id })->hashes->size;
    is $registry_count, 0, 'no payment row in registry schema when gate fires';
};

# ---------------------------------------------------------------------------
# 3. Ready tenant, full flow: mark ready, intercept Stripe, drive the step,
#    assert payment row in tenant schema, correct Stripe Connect params.
# ---------------------------------------------------------------------------

# Mark the tenant Stripe Connect ready
$db->query(
    'UPDATE registry.tenants SET stripe_connect_account_id = $1, stripe_charges_enabled = TRUE, stripe_details_submitted = TRUE WHERE slug = $2',
    'acct_e2e', $slug,
);

# Link the tenant to the seeded 2% revenue-share plan so the charge-time
# resolver applies a 2% fee. A freshly provisioned tenant has
# platform_pricing_plan_id NULL (the one-time backfill ran before it existed),
# which would otherwise resolve to the Free 0% plan.
$db->query(q{
    UPDATE registry.tenants SET platform_pricing_plan_id = (
        SELECT id FROM registry.pricing_plans
         WHERE plan_scope = 'tenant'
           AND pricing_model_type = 'percentage'
           AND metadata->>'default' IS DISTINCT FROM 'true'
         ORDER BY created_at
         LIMIT 1
    ) WHERE slug = ?
}, $slug);

my $captured_params;
my $captured_stripe_called = 0;

my $run  = make_e2e_run();
my $step = get_payment_step();
my $result;

{
    no warnings 'redefine';
    # The step drives Stripe through the async seam; a blocking call in the web
    # path can never settle inside the daemon's running event loop.
    local *Registry::Service::Stripe::create_payment_intent_async = sub {
        my ($self_stripe, $params) = @_;
        $captured_stripe_called++;
        $captured_params = $params;
        return Mojo::Promise->resolve({ id => 'pi_e2e', client_secret => 'cs_e2e' });
    };

    $result = settle($step->process($tdb, { agreeTerms => 1 }, $run));
}

subtest 'ready tenant: payment step passes gate and creates payment' => sub {
    ok !$result->{errors}, 'no gate error when tenant is Stripe Connect ready'
        or diag explain $result->{errors};
    is $captured_stripe_called, 1,
        'Stripe create_payment_intent_async was called exactly once';

    # Payment row must exist IN THE TENANT SCHEMA
    my $pay_rows = $tdb->select('payments', ['id', 'user_id', 'amount_cents', 'metadata'],
        { user_id => $parent->id })->hashes;
    is scalar @$pay_rows, 1, 'exactly one payment row in the tenant schema';

    # Registry schema must not have it
    my $reg_pay = $db->select('registry.payments', ['id'], { user_id => $parent->id })->hash;
    ok !$reg_pay, 'payment row NOT present in registry schema';
};

subtest 'Stripe params carry correct destination-charge and metadata keys' => sub {
    ok $captured_params, 'captured Stripe params are present';

    # Connect routing
    is $captured_params->{'transfer_data[destination]'}, 'acct_e2e',
        'transfer_data[destination] is the tenant account id';
    is $captured_params->{'on_behalf_of'}, 'acct_e2e',
        'on_behalf_of is the tenant account id';

    # Application fee derives from the fixture amount so the two cannot
    # drift; the round-half-up boundary itself is unit-tested in
    # t/dao/payment-intent-destination-charge.t.
    my $expected_fee = Registry::DAO::Payment::application_fee_cents($PLAN_AMOUNT_CENTS, 0.02);
    is $expected_fee, 300, q{expected fee sanity check: 2% of 15000 cents = 300 cents};
    is $captured_params->{'application_fee_amount'}, $expected_fee,
        'application_fee_amount matches expected 2% fee';

    # Bracket-notation metadata keys that Stripe echoes back in the webhook
    ok exists $captured_params->{'metadata[payment_id]'},
        'metadata[payment_id] bracket key present in Stripe params';
    ok exists $captured_params->{'metadata[tenant_slug]'},
        'metadata[tenant_slug] bracket key present in Stripe params';
    is $captured_params->{'metadata[tenant_slug]'}, $slug,
        'metadata[tenant_slug] value matches tenant slug';
};

# ---------------------------------------------------------------------------
# 4. Webhook finalization: synthesize the payment_intent.succeeded event from
#    captured params, drive _process_payment_intent_succeeded, assert payment
#    completed and enrollment exists IN the tenant schema, not registry.
# ---------------------------------------------------------------------------

# Extract what Stripe would echo back in the webhook metadata from our
# captured bracket-notation params.  This proves the data we send is
# sufficient for the webhook to route and finalize.
my $webhook_payment_id  = $captured_params->{'metadata[payment_id]'};
my $webhook_tenant_slug = $captured_params->{'metadata[tenant_slug]'};
my $webhook_pi_id       = 'pi_e2e';

ok $webhook_payment_id,  'payment_id extracted from captured Stripe bracket params';
ok $webhook_tenant_slug, 'tenant_slug extracted from captured Stripe bracket params';

# Build mock controller backed by our test DAO (same pattern as webhook-tenant-payment-finalization.t)
my $mock_log = Test::MockObject->new;
$mock_log->set_always('error', undef);
$mock_log->set_always('warn',  undef);
$mock_log->set_always('debug', undef);
$mock_log->set_always('info',  undef);

my $mock_app = Test::MockObject->new;
$mock_app->mock('dao', sub { $dao });
$mock_app->mock('log', sub { $mock_log });

my $wh = Registry::Controller::Webhooks->new;
$wh->{app} = $mock_app;

my $pi_succeeded_event = {
    type => 'payment_intent.succeeded',
    data => { object => {
        id       => $webhook_pi_id,
        metadata => {
            payment_id  => $webhook_payment_id,
            tenant_slug => $webhook_tenant_slug,
        },
    } },
};

subtest 'webhook finalizes payment and creates enrollment in tenant schema' => sub {
    # $tdb, not $dao: stripe() owns tenant routing now -- it resolves the slug
    # and sets a transaction-local search_path -- and the handler settles on
    # whatever connection it is handed. That routing is covered end to end over
    # HTTP in t/controller/webhook-tenant-payment-finalization.t; what this
    # integration test asserts is that finalization writes the whole settlement
    # into the tenant schema and nothing into registry.
    $wh->_process_payment_intent_succeeded($tdb, $pi_succeeded_event);

    # Payment completed in tenant schema
    my $payment = Registry::DAO::Payment->find($tdb, { id => $webhook_payment_id });
    ok $payment, 'payment found in tenant schema after webhook';
    is $payment->status, 'completed', 'payment status is completed';

    # Enrollment exists in tenant schema
    my $enrollments = $tdb->select('enrollments', '*',
        { payment_id => $webhook_payment_id })->hashes;
    is scalar @$enrollments, 1, 'exactly one enrollment created in tenant schema';
    is $enrollments->[0]{status}, 'active', 'enrollment status is active';

    # Neither payment completion nor enrollment visible in registry schema
    my $reg_enr = $db->select('registry.enrollments', ['id'],
        { payment_id => $webhook_payment_id })->hash;
    ok !$reg_enr, 'enrollment NOT created in registry schema';
};

# ---------------------------------------------------------------------------
# 5. Idempotency: call finalization a second time with the same event; the
#    dedup index (enrollment-payment-dedup) ensures exactly one enrollment.
#    We call _process_payment_intent_succeeded again directly (the dedup claim
#    in stripe() is bypassed in the unit style, which is the right test: it
#    proves finalize_enrollment itself is idempotent).
# ---------------------------------------------------------------------------

subtest 'finalization is idempotent: second webhook call yields exactly one enrollment' => sub {
    # Second call -- same event, fresh handler invocation
    $wh->_process_payment_intent_succeeded($tdb, $pi_succeeded_event);

    my $enrollments = $tdb->select('enrollments', '*',
        { payment_id => $webhook_payment_id })->hashes;
    is scalar @$enrollments, 1, 'still exactly one enrollment after second finalization call';
};

$test_db->cleanup_test_database;
done_testing;
