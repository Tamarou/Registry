#!/usr/bin/env perl
# ABOUTME: End-to-end test for tenant onboarding through registration.
# ABOUTME: Tests the full pipeline: programs exist -> storefront shows them -> parent registers -> enrollment created.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw(
    workflow_url
    workflow_process_step_url
);

use Registry::DAO qw(Workflow);
use Registry::DAO::User;
use Registry::DAO::Family;
use Registry::DAO::Enrollment;
use Registry::DAO::WorkflowRun;
use Mojo::Home;
use YAML::XS qw(Load);

# Ensure demo payment mode
delete $ENV{STRIPE_SECRET_KEY};

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

# Seeded DB templates (from registry-landing-page-template) override the
# default filesystem storefront with a marketing landing page that doesn't
# list programs. This test checks the program-listing view, so remove the
# override and let the default template render the created fixtures.
$dao->db->query(
    q{DELETE FROM templates WHERE name = 'tenant-storefront/program-listing'}
);

# Import all workflows
my @files = Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;
for my $file (@files) {
    next if Load($file->slurp)->{draft};
    Workflow->from_yaml($dao, $file->slurp);
}

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $dao });

# ============================================================
# Phase 1: Set up a tenant with programs and sessions
# (Simulates what Jordan would have after onboarding)
# ============================================================

subtest 'tenant has programs and sessions' => sub {
    my $location = $dao->create(Location => {
        name         => 'Super Awesome Cool Pottery Studio',
        slug         => 'sacp-studio',
        address_info => { street => '930 Hoffner Ave', city => 'Orlando', state => 'FL' },
        metadata     => {},
    });

    my $program = $dao->create(Project => {
        name              => "Potter's Wheel Art Camp - Summer 2026",
        notes             => 'FULL Day Camp | M-F | 9am-4pm | Grades K to 5',
        program_type_slug => 'summer-camp',
        metadata          => { age_range => { min => 5, max => 11 } },
    });

    my $teacher = $dao->create(User => {
        username => 'camp_instructor', user_type => 'staff',
    });

    my $session = $dao->create(Session => {
        name       => 'Week 1 - Jun 1-5',
        start_date => '2026-06-01',
        end_date   => '2026-06-05',
        status     => 'published',
        capacity   => 16,
        metadata   => {},
    });

    my $event = $dao->create(Event => {
        time        => '2026-06-01 09:00:00',
        duration    => 420,
        location_id => $location->id,
        project_id  => $program->id,
        teacher_id  => $teacher->id,
        capacity    => 16,
        metadata    => {},
    });
    $session->add_events($dao->db, $event->id);

    $dao->create(PricingPlan => {
        session_id => $session->id,
        plan_name  => 'Standard',
        plan_type  => 'standard',
        amount     => 300.00,
    });

    ok $session, 'Session created with events and pricing';
};

# ============================================================
# Phase 2: Storefront shows the program
# ============================================================

subtest 'storefront shows available programs' => sub {
    $t->get_ok('/')
      ->status_is(200);

    $t->content_like(qr/Potter.*Wheel Art Camp/i, 'Program visible on storefront');
    $t->content_like(qr/Super Awesome Cool Pottery Studio/i, 'Location visible on storefront');
    $t->content_like(qr/Register|Enroll/i, 'Registration button present');
};

# ============================================================
# Phase 3: Parent registers through the workflow
# ============================================================

subtest 'parent completes full registration' => sub {
    # Find the registration workflow
    my ($reg_wf) = $dao->find(Workflow => { slug => 'summer-camp-registration' });
    ok $reg_wf, 'Registration workflow exists';

    # Start the workflow
    $t->post_ok(workflow_url($reg_wf) => form => {})->status_is(302);
    my $run = $reg_wf->latest_run($dao->db);

    # Account check - create account
    my $step = $run->next_step($dao->db);
    is $step->slug, 'account-check', 'At account-check';

    $t->post_ok(workflow_process_step_url($reg_wf, $run, $step) => form => {
        action   => 'create_account',
        username => 'nancy.martinez',
        email    => 'nancy@example.com',
        name     => 'Nancy Martinez',
    })->status_is(302);

    # Pre-create child (stay semantics workaround)
    my $user = Registry::DAO::User->find($dao->db, { username => 'nancy.martinez' });
    ok $user, 'Parent account created';

    my $child = Registry::DAO::Family->add_child($dao->db, $user->id, {
        child_name        => 'Liam Martinez',
        birth_date        => '2017-09-01',
        grade             => '3',
        medical_info      => { allergies => ['peanuts'] },
        emergency_contact => { name => 'Sofia Martinez', phone => '407-555-0123' },
    });

    # Select children
    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    $step = $run->next_step($dao->db);
    $t->post_ok(workflow_process_step_url($reg_wf, $run, $step) => form => {
        action                   => 'continue',
        "child_${\$child->id}"   => 1,
    })->status_is(302);

    # Camper info
    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    $step = $run->next_step($dao->db);
    $t->post_ok(workflow_process_step_url($reg_wf, $run, $step) => form => {
        childName => 'Liam Martinez',
    })->status_is(302);

    # Session selection - find the session
    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    $step = $run->next_step($dao->db);

    my $session = Registry::DAO::Session->find($dao->db, { name => 'Week 1 - Jun 1-5' });
    $t->post_ok(workflow_process_step_url($reg_wf, $run, $step) => form => {
        action                        => 'select_sessions',
        "session_for_${\$child->id}"  => $session->id,
    })->status_is(302);

    # Payment (demo mode)
    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    $step = $run->next_step($dao->db);
    $t->post_ok(workflow_process_step_url($reg_wf, $run, $step) => form => {
        agreeTerms => 1,
    })->status_is(302);

    # Complete
    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    $step = $run->next_step($dao->db);
    $t->post_ok(workflow_process_step_url($reg_wf, $run, $step) => form => {})
      ->status_is(201);

    ($run) = $dao->find(WorkflowRun => { id => $run->id });
    ok $run->completed($dao->db), 'Registration workflow completed';
};

# ============================================================
# Phase 4: Enrollment exists in the database
# ============================================================

subtest 'enrollment created and visible' => sub {
    my $user = Registry::DAO::User->find($dao->db, { username => 'nancy.martinez' });
    my $children = Registry::DAO::Family->list_children($dao->db, $user->id);
    ok scalar @$children >= 1, 'Child exists for parent';

    my $child = $children->[0];
    my $session = Registry::DAO::Session->find($dao->db, { name => 'Week 1 - Jun 1-5' });

    my $enrollment = Registry::DAO::Enrollment->find($dao->db, {
        family_member_id => $child->id,
        session_id       => $session->id,
    });

    ok $enrollment, 'Enrollment exists in database';
    is $enrollment->status, 'active', 'Enrollment is active';

    # Enrollment count reflects the new registration
    my $count = Registry::DAO::Enrollment->count_for_session(
        $dao->db, $session->id, ['active', 'pending']
    );
    is $count, 1, 'Session has 1 enrollment';
};

# ============================================================
# Phase 5: Storefront reflects updated availability
# ============================================================

subtest 'storefront renders after enrollment' => sub {
    $t->get_ok('/')
      ->status_is(200);

    # Catalog still shows the program after enrollment
    $t->content_like(qr/Potter.*Wheel Art Camp/i, 'Program still visible after enrollment');
    $t->content_unlike(qr/Internal Server Error/, 'No server error');
};

done_testing;
