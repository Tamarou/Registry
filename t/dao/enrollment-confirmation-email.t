#!/usr/bin/env perl
# ABOUTME: Verifies that parents get an enrollment_confirmation email
# ABOUTME: after a successful Stripe payment (and in demo mode).
use 5.42.0;
use warnings;
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }
use lib qw(lib t/lib);
use Test::More;
use Test::MockObject;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::Payment;
use Registry::DAO::WorkflowSteps::Payment;
use Registry::DAO::Location;
use Registry::DAO::Session;
use Registry::DAO::Event;
use Registry::DAO::Project;
use Registry::DAO::FamilyMember;
use Registry::DAO::Notification;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

my $tenant = Test::Registry::Fixtures::create_tenant($dao->db, {
    name => 'Confirmation Email Tenant',
    slug => 'confirm_email',
});
$dao->db->query('SELECT clone_schema(?)', 'confirm_email');
$dao = Registry::DAO->new(url => $test_db->uri, schema => 'confirm_email');
my $db = $dao->db;

# --- Fixtures -------------------------------------------------------------

my $parent = Registry::DAO::User->create($db, {
    name      => 'Pat Parent',
    username  => 'parent_confirm',
    email     => 'pat@parent.local',
    user_type => 'parent',
    password  => 'x',
});

my $child = Registry::DAO::FamilyMember->create($db, {
    family_id  => $parent->id,
    child_name => 'Kiddo',
    birth_date => '2018-04-01',
    grade      => 'K',
});

my $teacher = Registry::DAO::User->create($db, {
    name      => 'Ms Teacher',
    username  => 'mst_confirm',
    email     => 'teach@school.local',
    user_type => 'staff',
    password  => 'x',
});

my $location = Registry::DAO::Location->create($db, {
    name         => 'Riverside Elementary',
    address_info => { city => 'Orlando', state => 'FL' },
    capacity     => 20,
});

my $project = Registry::DAO::Project->create($db, {
    name              => 'Fall Art',
    status            => 'published',
});

my $session = Registry::DAO::Session->create($db, {
    name       => 'Fall Art Session 1',
    start_date => '2099-09-01',
    end_date   => '2099-12-15',
    status     => 'published',
    capacity   => 15,
});

my $event = Registry::DAO::Event->create($db, {
    session_id  => $session->id,
    time        => '2099-09-05 15:00:00',
    duration    => 60,
    location_id => $location->id,
    project_id  => $project->id,
    teacher_id  => $teacher->id,
});

# --- Workflow + step ------------------------------------------------------

my $workflow = Registry::DAO::Workflow->create($db, {
    name        => 'Confirm Email Flow',
    slug        => 'confirm_email_flow',
    description => 'minimal',
    first_step  => 'payment',
});
$workflow->add_step($db, {
    slug        => 'payment',
    description => 'Payment',
    class       => 'Registry::DAO::WorkflowSteps::Payment',
});
my $run = $workflow->new_run($db);
$run->update_data($db, {
    user_id          => $parent->id,
    enrollment_items => [{ session_id => $session->id, child_id => $child->id }],
});

my $step = Registry::DAO::WorkflowStep->find($db, {
    workflow_id => $workflow->id, slug => 'payment',
});

# Count enrollment_confirmation notifications for this parent.
sub confirmation_count ($db, $user_id) {
    $db->query(
        "SELECT COUNT(*) FROM notifications
         WHERE user_id = ? AND type = 'enrollment_confirmation'",
        $user_id,
    )->array->[0];
}

subtest 'demo mode (no Stripe key) queues a confirmation' => sub {
    my $before = confirmation_count($db, $parent->id);

    local $ENV{STRIPE_SECRET_KEY};
    delete $ENV{STRIPE_SECRET_KEY};

    my $result = $step->create_demo_enrollments($db, $run, {
        agreeTerms => 1,
    });
    is($result->{next_step}, 'complete', 'advances to complete');

    my $after = confirmation_count($db, $parent->id);
    is($after, $before + 1, 'one enrollment_confirmation queued');
};

subtest 'helper queues one notification per enrollment item' => sub {
    # _queue_enrollment_confirmations is called by both the demo and
    # Stripe success paths. Exercise it directly with multiple items
    # to confirm one-notification-per-item behavior without needing to
    # thread real Payment / Enrollment rows through.
    my $session2 = Registry::DAO::Session->create($db, {
        name       => 'Fall Art Session 2',
        start_date => '2099-10-01',
        end_date   => '2099-12-15',
        status     => 'published',
        capacity   => 15,
    });
    Registry::DAO::Event->create($db, {
        session_id  => $session2->id,
        time        => '2099-10-05 15:00:00',
        duration    => 60,
        location_id => $location->id,
        project_id  => $project->id,
        teacher_id  => $teacher->id,
    });

    my $before = confirmation_count($db, $parent->id);

    $step->_queue_enrollment_confirmations(
        $db, $parent->id,
        [
            { session_id => $session->id,  child_id => $child->id },
            { session_id => $session2->id, child_id => $child->id },
        ],
    );

    my $after = confirmation_count($db, $parent->id);
    is($after, $before + 2, 'two notifications for two enrollment items');
};

subtest 'confirmation carries session and location details' => sub {
    # Pull the first notification we created (demo-mode subtest)
    my $row = $db->query(
        "SELECT subject, metadata FROM notifications
         WHERE user_id = ? AND type = 'enrollment_confirmation'
         ORDER BY created_at ASC LIMIT 1",
        $parent->id,
    )->expand->hash;
    ok($row, 'notification row exists');
    my $meta = $row->{metadata} || {};
    is($meta->{event_name}, 'Fall Art Session 1',
       'session name captured for template');
    is($meta->{location_name}, 'Riverside Elementary',
       'location captured for template');
    ok($meta->{start_date}, 'start_date included in metadata');
};

done_testing();
