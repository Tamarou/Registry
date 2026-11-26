#!/usr/bin/env perl
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
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
use Mojo::JSON qw(encode_json);
use Test::Registry::Async qw( settle );

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

# Create test tenant and set up schema
my $tenant = Test::Registry::Fixtures::create_tenant($dao->db, {
    name => 'Test Payment Tenant',
    slug => 'test_payment',
});
$dao->db->query('SELECT clone_schema(?)', 'test_payment');

# Switch to tenant schema
$dao = Registry::DAO->new(url => $test_db->uri, schema => 'test_payment');
my $db = $dao->db;

# Create test data
my $location = Registry::DAO::Location->create($db, { time_zone => 'America/New_York',
    name => 'Test Location',
    address_info => {
        street_address => '123 Main St',
        city => 'Test City',
        state => 'TS',
        postal_code => '12345'
    },
    metadata => {}
});

# Create teacher and project first
my $teacher = Registry::DAO::User->create($db, {
    name => 'Test Teacher',
    username => 'testteacher',
    email => 'teacher@test.com',
    user_type => 'staff'
});

my $project = Registry::DAO::Project->create($db, {
    name => 'Test Project',
    metadata => {}
});

my $event = Registry::DAO::Event->create($db, {
    time => '2024-07-01 10:00:00',
    duration => 120,
    location_id => $location->id,
    project_id => $project->id,
    teacher_id => $teacher->id,
    metadata => {},
    capacity => 20
});

my $session = Registry::DAO::Session->create($db, {
    name => 'Test Session',
    start_date => '2024-07-02',
    end_date => '2024-07-09',
    status => 'published',
    metadata => {}
});

# Link event to session
$session->add_events($db, $event->id);

Registry::DAO::PricingPlan->create($db, {
    session_id => $session->id,
    plan_name => 'Standard',
    plan_type => 'standard',
    amount_cents => 15000
});

# Create workflow
my $workflow = Registry::DAO::Workflow->create($db, {
    name => 'Test Payment Workflow',
    slug => 'test-payment-workflow',
    description => 'Test workflow for payment processing'
});

# Add workflow steps
my $payment_step_data = Registry::DAO::WorkflowStep->create($db, {
    workflow_id => $workflow->id,
    slug => 'payment',
    class => 'Registry::DAO::WorkflowSteps::Payment',
    description => 'Payment processing step'
});

my $complete_step_data = Registry::DAO::WorkflowStep->create($db, {
    workflow_id => $workflow->id,
    slug => 'complete',
    class => 'Registry::DAO::WorkflowStep',
    description => 'Completion step',
    depends_on => $payment_step_data->id
});

# Update workflow to set first step
$workflow->update($db, { first_step => 'payment' }, { id => $workflow->id });

# Create test parent user
my $parent = Registry::DAO::User->create($db, {
    email    => 'parent@example.com',
    username => 'testparent',
    password => 'password123',
    name => 'Test Parent',
    user_type => 'parent'
});

# Add children to family using correct data model
my $child1 = Registry::DAO::Family->add_child($db, $parent->id, {
    child_name => 'Alice Smith',
    birth_date => '2016-03-15',  # 8 years old
    grade => '3',
    medical_info => {},
    emergency_contact => {
        name => 'Emergency Contact',
        phone => '555-0123'
    }
});

my $child2 = Registry::DAO::Family->add_child($db, $parent->id, {
    child_name => 'Bob Smith',
    birth_date => '2014-06-20',  # 10 years old
    grade => '5',
    medical_info => {},
    emergency_contact => {
        name => 'Emergency Contact',
        phone => '555-0123'
    }
});

subtest 'Payment step data preparation' => sub {
    my $run = $workflow->new_run($db);

    # Set up run data as if coming from previous steps
    $run->update_data($db, {
        user_id => $parent->id,
        children => [
            {
                id => $child1->id,
                first_name => 'Alice',
                last_name => 'Smith',
                birth_date => '2016-03-15',
                grade => '3'
            },
            {
                id => $child2->id,
                first_name => 'Bob',
                last_name => 'Smith',
                birth_date => '2014-06-20',
                grade => '5'
            }
        ],
        session_selections => {
            $child1->id => $session->id,
            $child2->id => $session->id
        }
    });

    # Get the actual payment step from database
    my $payment_step = $workflow->get_step($db, { slug => 'payment' });

    # Process step without form data to get payment page
    my $result = $payment_step->process($db, {});

    is $result->{next_step}, $payment_step->id, 'Stays on payment step';
    ok $result->{data}, 'Payment data prepared';
    cmp_ok $result->{data}{step_data}{total}, '==', 30000, 'Total calculated correctly (15000 cents * 2)';
    is scalar(@{$result->{data}{step_data}{items}}), 2, 'Two line items prepared';
};

subtest 'Payment creation without Stripe' => sub {
    my $run = $workflow->new_run($db);

    # Set up run data
    $run->update_data($db, {
        user_id => $parent->id,
        children => [
            {
                id => $child1->id,
                first_name => 'Alice',
                last_name => 'Smith',
                birth_date => '2016-03-15',
                grade => '3'
            }
        ],
        session_selections => {
            $child1->id => $session->id
        }
    });

    # Skip actual Stripe integration
    local $ENV{STRIPE_SECRET_KEY} = undef;
    local $ENV{STRIPE_PUBLISHABLE_KEY} = undef;

    # Get the actual payment step from database
    my $payment_step = $workflow->get_step($db, { slug => 'payment' });

    # Test that we can prepare payment data
    my $payment_data = $payment_step->prepare_payment_data($db, $run);

    ok $payment_data, 'Payment data prepared';
    cmp_ok $payment_data->{total}, '==', 15000, 'Correct total for single enrollment';
    is scalar(@{$payment_data->{items}}), 1, 'One line item';

    # We can't test actual payment creation without Stripe or fixing the User foreign key issue
    # The Payment step would need to be refactored to handle test mode better
};

subtest 'Calculate enrollment totals' => sub {
    # Test the calculate_enrollment_total method directly
    my $enrollment_data = {
        children => [
            {
                id => $child1->id,
                first_name => 'Alice',
                last_name => 'Smith'
            },
            {
                id => $child2->id,
                first_name => 'Bob',
                last_name => 'Smith'
            }
        ],
        session_selections => {
            $child1->id => $session->id,
            $child2->id => $session->id
        }
    };

    my $payment_info = Registry::DAO::Payment->calculate_enrollment_total($db, $enrollment_data);

    cmp_ok $payment_info->{total}, '==', 30000, 'Total is 30000 cents for two enrollments';
    is scalar(@{$payment_info->{items}}), 2, 'Two line items generated';

    # Money is integer cents end to end, so these compare as integers.
    my $item1 = $payment_info->{items}->[0];
    cmp_ok $item1->{amount_cents}, '==', 15000, 'First item is 15000 cents';
    like $item1->{description}, qr/Alice Smith/, 'First item mentions Alice';
    like $item1->{description}, qr/Test Session/, 'First item mentions session';

    my $item2 = $payment_info->{items}->[1];
    cmp_ok $item2->{amount_cents}, '==', 15000, 'Second item is 15000 cents';
    like $item2->{description}, qr/Bob Smith/, 'Second item mentions Bob';
};

# A paid run through this step in a real tenant schema is covered elsewhere:
# t/stripe-live/paid-enrollment.t, 'direct charge lands on the tenant account
# with the plan fee' (payment_id handed back, real intent, charged at the plan
# price), and t/integration/tenant-paid-enrollment.t, 'ready tenant: payment
# step passes gate and creates payment' (one row, for the parent, in the tenant
# schema).

subtest 'priced cart without Stripe is refused, nothing enrolled' => sub {
    local $ENV{STRIPE_SECRET_KEY} = undef;

    my $run = $workflow->new_run($db);

    # Set up run data as if coming from previous steps
    $run->update_data($db, {
        user_id => $parent->id,
        selected_child_ids => [$child1->id],
        children => [ { id => $child1->id, first_name => 'Alice', last_name => 'Smith' } ],
        enrollment_items => [
            { child_id => $child1->id, session_id => $session->id },
        ],
        session_selections => {
            $child1->id => $session->id,
        },
    });

    # Get the actual payment step from database
    my $payment_step = $workflow->get_step($db, { slug => 'payment' });

    my @warnings;
    my $result = do {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        settle( $payment_step->process($db, { agreeTerms => 1 }) );
    };
    like "@warnings", qr/STRIPE_SECRET_KEY is not set/, 'the refusal is logged';

    is_deeply $result->{errors},
        [ Registry::DAO::WorkflowSteps::Payment->payment_unavailable_message ],
        'refused: a priced cart is never enrolled for free';
    isnt $result->{next_step}, 'complete', 'stays on the payment step';

    my $enrollment = $db->select('enrollments', '*', {
        family_member_id => $child1->id,
        session_id       => $session->id,
    })->hash;
    ok !$enrollment, 'nothing enrolled';
};

# A free registration where one sibling takes a seat and the other waits for a
# session that had none. The waiting child is joined at completion, not when the
# session was picked -- an abandoned form must not leave anyone in a queue.
subtest '$0 cart: a child who chose to wait is put on the waitlist' => sub {
    local $ENV{STRIPE_SECRET_KEY} = undef;

    my $full_event = Registry::DAO::Event->create($db, {
        time => '2024-07-01 14:00:00',
        duration => 120,
        location_id => $location->id,
        project_id => $project->id,
        teacher_id => $teacher->id,
        metadata => {},
        capacity => 1,
    });
    my $full_session = Registry::DAO::Session->create($db, {
        name => 'Full Session',
        start_date => '2024-07-02',
        end_date => '2024-07-09',
        status => 'published',
        capacity => 1,
        metadata => {},
    });
    $full_session->add_events($db, $full_event->id);

    # The seated child's session is free: only a $0 cart completes without Stripe.
    my $free_session = Registry::DAO::Session->create($db, {
        name => 'Free Session', start_date => '2024-07-02', end_date => '2024-07-09',
        status => 'published', metadata => {},
    });
    $free_session->add_events($db, $event->id);
    Registry::DAO::PricingPlan->create($db, {
        session_id => $free_session->id, plan_name => 'Free', plan_type => 'standard', amount_cents => 0,
    });

    my $run = $workflow->new_run($db);
    $run->update_data($db, {
        user_id => $parent->id,
        selected_child_ids => [ $child1->id, $child2->id ],
        children => [ { id => $child2->id, first_name => 'Bob', last_name => 'Smith' } ],
        enrollment_items => [
            { child_id => $child2->id, session_id => $free_session->id },
        ],
        session_selections => { $child2->id => $free_session->id },
        waitlist_items => [
            { child_id => $child1->id, session_id => $full_session->id,
              location_id => $location->id },
        ],
    });

    my $payment_step = $workflow->get_step($db, { slug => 'payment' });
    my $result = $payment_step->process($db, { agreeTerms => 1 });

    is $result->{next_step}, 'complete', 'the registration completes';
    ok !$result->{errors}, 'with no errors' or diag explain $result->{errors};

    my $entry = $db->select('waitlist', '*', {
        session_id => $full_session->id,
        student_id => $child1->id,
    })->hash;

    ok $entry, 'the waiting child is on the waitlist';
    is $entry->{status}, 'waiting', 'as waiting';
    is $entry->{parent_id}, $parent->id, 'attributed to the registering parent';

    my $seated = $db->select('enrollments', '*', {
        family_member_id => $child1->id,
        session_id       => $full_session->id,
    })->hash;
    ok !$seated, 'and holds no enrollment -- there was no seat to give';
};

done_testing;