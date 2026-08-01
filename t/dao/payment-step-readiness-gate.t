#!/usr/bin/env perl
# ABOUTME: Tests the Stripe Connect readiness gate in the Payment workflow step.
# ABOUTME: Paid enrollment must be blocked when the tenant's connected account is not ready.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
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
use Registry::Service::Stripe;
use Mojo::Promise;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

# Provision a fresh tenant so we have a real tenant schema with proper isolation.
# Tenant->provision creates the tenant row in registry.tenants AND clones the schema.
my $slug = 'gate_test_' . $$;
my $admin = Registry::DAO::User->create($db, {
    username  => "gate_admin_$$",
    email     => "gate_admin_$$\@test.example",
    name      => 'Gate Admin',
    user_type => 'admin',
});

my $tenant = Registry::DAO::Tenant->provision($db, {
    name  => "Gate Test $$",
    slug  => $slug,
    users => [ $admin ],
});
ok $tenant, 'tenant provisioned';

# Connect to the tenant schema for all fixture creation.
my $tenant_dao = Registry::DAO->new(url => $test_db->uri, schema => $slug);
my $tenant_db  = $tenant_dao->db;

# ---- build shared fixtures in the tenant schema ----------------------------

my $location = Registry::DAO::Location->create($tenant_db, {
    name         => 'Gate Test Location',
    address_info => { street_address => '1 Gate St', city => 'T', state => 'TS', postal_code => '12345' },
    metadata     => {},
});

my $teacher = Registry::DAO::User->create($tenant_db, {
    name      => 'Gate Teacher',
    username  => "gate_teacher_$$",
    email     => "gate_teacher_$$\@test.com",
    user_type => 'staff',
});

my $project = Registry::DAO::Project->create($tenant_db, {
    name     => 'Gate Test Project',
    metadata => {},
});

my $event = Registry::DAO::Event->create($tenant_db, {
    time        => '2024-07-01 10:00:00',
    duration    => 120,
    location_id => $location->id,
    project_id  => $project->id,
    teacher_id  => $teacher->id,
    metadata    => {},
    capacity    => 20,
});

# Paid session: $150 per enrollment
my $paid_session = Registry::DAO::Session->create($tenant_db, {
    name       => 'Paid Session',
    start_date => '2024-07-02',
    end_date   => '2024-07-09',
    status     => 'published',
    metadata   => {},
});
$paid_session->add_events($tenant_db, $event->id);
Registry::DAO::PricingPlan->create($tenant_db, {
    session_id => $paid_session->id,
    plan_name  => 'Standard',
    plan_type  => 'standard',
    amount     => 150.00,
});

# Free session: $0 enrollment
my $free_session = Registry::DAO::Session->create($tenant_db, {
    name       => 'Free Session',
    start_date => '2024-07-02',
    end_date   => '2024-07-09',
    status     => 'published',
    metadata   => {},
});
$free_session->add_events($tenant_db, $event->id);
Registry::DAO::PricingPlan->create($tenant_db, {
    session_id => $free_session->id,
    plan_name  => 'Free',
    plan_type  => 'standard',
    amount     => 0.00,
});

# Build the workflow in the tenant schema
my $workflow = Registry::DAO::Workflow->create($tenant_db, {
    name        => 'Gate Test Workflow',
    slug        => "gate-test-workflow-$$",
    description => 'Workflow for readiness gate tests',
});

my $payment_step_row = Registry::DAO::WorkflowStep->create($tenant_db, {
    workflow_id => $workflow->id,
    slug        => 'payment',
    class       => 'Registry::DAO::WorkflowSteps::Payment',
    description => 'Payment processing step',
});

my $complete_step_row = Registry::DAO::WorkflowStep->create($tenant_db, {
    workflow_id => $workflow->id,
    slug        => 'complete',
    class       => 'Registry::DAO::WorkflowStep',
    description => 'Completion step',
    depends_on  => $payment_step_row->id,
});

$workflow->update($tenant_db, { first_step => 'payment' }, { id => $workflow->id });

# Create a parent user and child in the tenant schema
my $parent = Registry::DAO::User->create($tenant_db, {
    email     => "gate_parent_$$\@example.com",
    username  => "gate_parent_$$",
    name      => 'Gate Parent',
    user_type => 'parent',
});

my $child = Registry::DAO::Family->add_child($tenant_db, $parent->id, {
    child_name        => 'Gate Child',
    birth_date        => '2016-03-15',
    grade             => '3',
    medical_info      => {},
    emergency_contact => { name => 'Emergency', phone => '555-0123' },
});

# Helper: get the real payment step object from the DB
sub get_payment_step {
    return $workflow->get_step($tenant_db, { slug => 'payment' });
}

# Helper: build a run seeded for a paid enrollment, with __tenant_slug set
sub make_paid_run {
    my $run = $workflow->new_run($tenant_db);
    $run->update_data($tenant_db, {
        user_id            => $parent->id,
        children           => [ {
            id         => $child->id,
            first_name => 'Gate',
            last_name  => 'Child',
            birth_date => '2016-03-15',
            grade      => '3',
        } ],
        session_selections => { $child->id => $paid_session->id },
        enrollment_items   => [ { child_id => $child->id, session_id => $paid_session->id } ],
        __tenant_slug      => $slug,
    });
    return $run;
}

# ---- case (a): paid enrollment, tenant NOT Stripe-ready - gate blocks ------
subtest 'paid + tenant not ready: gate returns error, no payment row' => sub {
    # Confirm tenant is NOT ready (no Stripe Connect columns set yet)
    ok !$tenant->stripe_connect_ready, 'tenant not yet Stripe Connect ready';

    local $ENV{STRIPE_SECRET_KEY} = 'sk_test_dummy';

    my $run  = make_paid_run();
    my $step = get_payment_step();

    my $result = settle($step->process($tenant_db, { agreeTerms => 1 }, $run));

    ok $result->{errors}, 'gate returned errors';
    like $result->{errors}[0], qr/not yet available/i,
        'error message mentions unavailability';
    is $result->{next_step}, $step->id, 'stays on payment step (not advanced)';

    # No payment row should have been created
    my $pay_count = $tenant_db->select('payments', ['id'], { user_id => $parent->id })->hashes->size;
    is $pay_count, 0, 'no payment row created when gate fires';
};

# ---- case (b): paid enrollment, tenant IS Stripe-ready - proceeds ----------
subtest 'paid + tenant ready: gate passes, payment row created' => sub {
    # Mark the tenant as Stripe Connect ready in registry.tenants
    $db->query(
        'UPDATE registry.tenants SET stripe_connect_account_id = $1, stripe_charges_enabled = TRUE, stripe_details_submitted = TRUE WHERE slug = $2',
        'acct_gate_test', $slug,
    );

    local $ENV{STRIPE_SECRET_KEY} = 'sk_test_dummy';

    # Intercept Stripe so we don't hit the network
    my $intent_called = 0;
    {
        no warnings 'redefine';
        # The step drives Stripe through the async seam; a blocking call in the
        # web path can never settle inside the daemon's running event loop.
        local *Registry::Service::Stripe::create_payment_intent_async = sub {
            $intent_called++;
            return Mojo::Promise->resolve(
                { id => 'pi_gate_test', client_secret => 'cs_gate_test' });
        };

        my $run  = make_paid_run();
        my $step = get_payment_step();

        my $result = settle($step->process($tenant_db, { agreeTerms => 1 }, $run));

        ok !$result->{errors}, 'no gate error when tenant is ready'
            or diag explain $result->{errors};
        ok $intent_called, 'Stripe payment intent was called';

        # A payment row must exist in the tenant schema
        my $pay_count = $tenant_db->select('payments', ['id'], { user_id => $parent->id })->hashes->size;
        ok $pay_count > 0, 'payment row created in tenant schema';
    }
};

# ---- case (c): free enrollment, tenant NOT ready - gate exempt -------------
subtest 'free ($0) + tenant not ready: no gate error, enrollment completes' => sub {
    # Reset the tenant back to NOT ready
    $db->query(
        'UPDATE registry.tenants SET stripe_connect_account_id = NULL, stripe_charges_enabled = FALSE, stripe_details_submitted = FALSE WHERE slug = ?',
        $slug,
    );

    # Free enrollment: STRIPE_SECRET_KEY present, but total is $0 so process()
    # routes to create_demo_enrollments BEFORE reaching create_payment.  The
    # gate only lives in create_payment, so free totals are naturally exempt.
    # We prove this by asserting the free path completes ungated even when the
    # tenant has no Stripe Connect account at all.
    local $ENV{STRIPE_SECRET_KEY} = 'sk_test_dummy';

    my $run = $workflow->new_run($tenant_db);
    $run->update_data($tenant_db, {
        user_id            => $parent->id,
        children           => [ {
            id         => $child->id,
            first_name => 'Gate',
            last_name  => 'Child',
            birth_date => '2016-03-15',
            grade      => '3',
        } ],
        session_selections => { $child->id => $free_session->id },
        enrollment_items   => [ { child_id => $child->id, session_id => $free_session->id } ],
        __tenant_slug      => $slug,
    });

    my $step   = get_payment_step();
    my $result = settle($step->process($tenant_db, { agreeTerms => 1 }, $run));

    # Free path routes via create_demo_enrollments which returns next_step => 'complete'
    # before the gate is ever evaluated.
    is $result->{next_step}, 'complete',
        'free enrollment advances to complete without hitting the gate';
    ok !$result->{errors}, 'no errors on free enrollment'
        or diag explain $result->{errors};

    my $enrollment = $tenant_db->query(
        'SELECT status FROM enrollments WHERE session_id = ? AND family_member_id = ?',
        $free_session->id, $child->id
    )->hash;
    ok $enrollment, 'free enrollment created despite tenant not being Stripe-ready';
    is $enrollment->{status}, 'active', 'free enrollment is active';
};

$test_db->cleanup_test_database;
done_testing;
