#!/usr/bin/env perl
# ABOUTME: Controller tests for the tenant-storefront workflow.
# ABOUTME: Tests program listing, availability display, callcc registration, and tenant isolation.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Helpers;
use Test::Registry::Fixtures;

use Registry::DAO qw(Workflow);
use Registry::DAO::User;
use Registry::DAO::Enrollment;
use Mojo::Home;
use Mojo::JSON qw(encode_json);
use YAML::XS qw(Load);

# Ensure demo payment mode
delete $ENV{STRIPE_SECRET_KEY};

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

# The seeded DB template for tenant-storefront/program-listing renders a
# marketing landing page that doesn't list programs. This controller test
# asserts on the default filesystem template's program listing view, so
# drop the DB override here.
$dao->db->query(
    q{DELETE FROM templates WHERE name = 'tenant-storefront/program-listing'}
);

# Import all workflows from YAML
my @files = Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;
for my $file (@files) {
    next if Load($file->slurp)->{draft};
    Workflow->from_yaml($dao, $file->slurp);
}

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $dao });

# --- Test Data Setup ---

my $location = $dao->create(Location => {
    name         => 'Super Awesome Cool Pottery Studio',
    slug         => 'sacp-studio',
    address_info => { street => '930 Hoffner Ave', city => 'Orlando', state => 'FL' },
    metadata     => {},
});

my $program = $dao->create(Project => { status => 'published',
    name              => "Potter's Wheel Art Camp",
    notes             => 'FULL Day Camp | M-F | 9am-4pm | Grades K to 5',
    program_type_slug => 'summer-camp',
    metadata          => { age_range => { min => 5, max => 11 } },
});

my $teacher = $dao->create(User => { username => 'sf_teacher', user_type => 'staff' });

# Compute future dates relative to today so this test remains valid over time
my $future_start = days_from_now(30);
my $future_end   = days_from_now(37);
my $full_start   = days_from_now(45);
my $full_end     = days_from_now(52);
my $draft_start  = days_from_now(60);
my $draft_end    = days_from_now(67);

# Open session with capacity
my $session1 = $dao->create(Session => {
    name       => 'Week 1 - Open',
    start_date => $future_start,
    end_date   => $future_end,
    status     => 'published',
    capacity   => 16,
    metadata   => {},
});

my $event1 = $dao->create(Event => {
    time        => "$future_start 09:00:00",
    duration    => 420,
    location_id => $location->id,
    project_id  => $program->id,
    teacher_id  => $teacher->id,
    capacity    => 16,
    metadata    => {},
});
$session1->add_events($dao->db, $event1->id);

$dao->create(PricingPlan => {
    session_id => $session1->id,
    plan_name  => 'Standard',
    plan_type  => 'standard',
    amount_cents => 30000,
});

# Full session (capacity 2, filled)
my $session_full = $dao->create(Session => {
    name       => 'Week 3 - Full',
    start_date => $full_start,
    end_date   => $full_end,
    status     => 'published',
    capacity   => 2,
    metadata   => {},
});

my $event_full = $dao->create(Event => {
    time        => "$full_start 09:00:00",
    duration    => 420,
    location_id => $location->id,
    project_id  => $program->id,
    teacher_id  => $teacher->id,
    capacity    => 2,
    metadata    => {},
});
$session_full->add_events($dao->db, $event_full->id);

$dao->create(PricingPlan => {
    session_id => $session_full->id,
    plan_name  => 'Standard',
    plan_type  => 'standard',
    amount_cents => 30000,
});

# Fill the session
for my $i (1..2) {
    my $fp = $dao->create(User => {
        username => "sf_filler_$i", name => "Filler $i",
        user_type => 'parent', email => "sf_filler_$i\@example.com",
    });
    my $fc = Registry::DAO::Family->add_child($dao->db, $fp->id, {
        child_name => "Filler Kid $i", birth_date => '2018-01-01', grade => '3',
        medical_info => {}, emergency_contact => { name => 'P', phone => '555' },
    });
    $dao->db->insert('enrollments', {
        session_id => $session_full->id, student_id => $fp->id,
        family_member_id => $fc->id, status => 'active',
    });
}

# Draft session (should NOT appear). Its window is in the future so that
# status is the only thing keeping it out of the listing.
my $session_draft = $dao->create(Session => {
    name       => 'Draft Session',
    start_date => $draft_start,
    end_date   => $draft_end,
    status     => 'draft',
    capacity   => 16,
    metadata   => {},
});

use Registry::DAO::Family;

# ============================================================
# Test 1: GET / returns 200 with program listing
# ============================================================
subtest 'GET / returns 200 with program listing' => sub {
    $t->get_ok('/tenant-storefront')
      ->status_is(200);

    # Program name appears
    $t->content_like(qr/Potter.*Wheel Art Camp/i, 'Program name visible');

    # Location name appears
    $t->content_like(qr/Super Awesome Cool Pottery Studio/, 'Location visible');

    # Register button exists
    $t->content_like(qr/Register|Enroll/i, 'Register/Enroll button visible');

    # No errors
    $t->content_unlike(qr/Internal Server Error/, 'No server error');
};

# ============================================================
# Test 2: Only published sessions shown
# ============================================================
subtest 'only published sessions with future dates shown' => sub {
    $t->get_ok('/tenant-storefront')
      ->status_is(200);

    # Published programs with sessions appear (dates visible)
    $t->content_like(qr/\Q$future_start\E/, 'Published session dates visible');

    # Draft session does NOT appear
    $t->content_unlike(qr/Draft Session/, 'Draft session not visible');
};

# ============================================================
# Test 3: Full session shows waitlist option
# ============================================================
subtest 'program cards have callcc registration links' => sub {
    $t->get_ok('/tenant-storefront')
      ->status_is(200);

    # Program card has a callcc form for registration
    my $dom = $t->tx->res->dom;
    my @forms = $dom->find('form[action*="callcc"]')->each;
    ok @forms >= 1, 'At least one callcc registration form found';
};

# ============================================================
# Test 4: callcc Register button works
# ============================================================
subtest 'callcc Register button creates continuation to registration' => sub {
    # First GET to create a run
    $t->get_ok('/tenant-storefront')->status_is(200);

    # Find a callcc form that targets summer-camp-registration
    # (the test program has no registration_workflow metadata, so it defaults)
    my $dom = $t->tx->res->dom;
    my $callcc_form = $dom->at('form[action*="callcc/summer-camp-registration"]');
    ok $callcc_form, 'callcc form for summer-camp-registration found';

    if ($callcc_form) {
        my $action = $callcc_form->attr('action');

        # POST to the callcc URL
        $t->post_ok($action => form => {})->status_is(302);

        my $redirect = $t->tx->res->headers->location;
        like $redirect, qr/summer-camp-registration/,
            'Redirected to registration workflow';
    }
};

# ============================================================
# Test 5: callcc target respects project metadata registration_workflow
# ============================================================
subtest 'callcc target uses registration_workflow from project metadata' => sub {
    # Update the program metadata to specify a custom registration workflow
    $dao->db->update('projects',
        { metadata => encode_json({ age_range => { min => 5, max => 11 }, registration_workflow => 'tenant-signup' }) },
        { id => $program->id },
    );

    $t->get_ok('/tenant-storefront')->status_is(200);

    my $dom = $t->tx->res->dom;
    my $callcc_form = $dom->at('form[action*="callcc"]');
    ok $callcc_form, 'callcc form found in page';

    if ($callcc_form) {
        my $action = $callcc_form->attr('action');
        like $action, qr{/tenant-storefront/.+/callcc/tenant-signup},
            'callcc action targets tenant-signup from project metadata';
    }

    # Restore original metadata
    $dao->db->update('projects',
        { metadata => encode_json({ age_range => { min => 5, max => 11 } }) },
        { id => $program->id },
    );
};

# ============================================================
# Test 6: Storefront uses design system classes not Tailwind
# ============================================================
subtest 'storefront uses design system classes not Tailwind' => sub {
    $t->get_ok('/tenant-storefront')
      ->status_is(200);

    # Design system classes present
    $t->element_exists('.landing-page', 'Uses landing-page container')
      ->element_exists('.landing-features', 'Uses landing-features section')
      ->element_exists('.landing-cta-button', 'Uses landing-cta-button for CTA');

    # Tailwind classes absent
    $t->content_unlike(qr/class="[^"]*bg-white/, 'No Tailwind bg-white class')
      ->content_unlike(qr/class="[^"]*text-gray/, 'No Tailwind text-gray class');
};

# ============================================================
# Test 7: No programs shows empty state
# ============================================================
# This subtest was `ok 1, 'Storefront renders without crashing (programs exist)'`
# under a comment conceding that the empty state was "tested implicitly by the
# template rendering". It was not tested at all: the branch never ran, because
# the fixture always has a published programme.
#
# The template has two empty states and they say different things -- a visitor
# who filtered everything out needs a way back, a visitor arriving at a storefront
# with nothing on it needs to know to return later. Both are asserted.
# The filter bar submits GET to "/", and nothing ever pressed it: `index` did not
# pass the request's params to the step, so ProgramListing never saw `location` or
# `program_type`. The selects still marked the chosen option -- the template reads
# param() directly -- so the screen showed a location selected above a list that
# had not been narrowed at all.
subtest 'the filter bar actually filters' => sub {
    # The real location keeps the programme. Asserted first, because a filter that
    # empties the page for every value is broken in the other direction.
    $t->get_ok('/tenant-storefront?location=' . $location->id)
      ->status_is(200)
      ->content_like(qr/Wheel Art Camp/,
          'filtering to the location the programme runs at keeps it');

    # And the programme type it belongs to.
    $t->get_ok('/tenant-storefront?program_type=summer-camp')
      ->status_is(200)
      ->content_like(qr/Wheel Art Camp/,
          'filtering to its programme type keeps it');

    # A type it does not belong to drops it.
    $t->get_ok('/tenant-storefront?program_type=after-school')
      ->status_is(200)
      ->content_unlike(qr/Wheel Art Camp/,
          'filtering to another programme type drops it');
};

subtest 'no programs shows empty state message' => sub {
    # Filtered to a location that matches nothing. The programme still exists, so
    # this is the "your filters are too narrow" state and it has to offer the way
    # back rather than an empty page.
    $t->get_ok('/tenant-storefront?location=' . '0' x 8 . '-0000-0000-0000-' . '0' x 12)
      ->status_is(200)
      ->content_like(qr/No programs match your filters/,
          'a filter that matches nothing says so')
      ->content_like(qr/view all programs/,
          'and offers the way back');

    # Nothing published at all. Unpublishing rather than building a second tenant
    # schema, because what the template branches on is the grouped-programs list
    # being empty and that is the state under test.
    $dao->db->query(q{UPDATE projects SET status = 'draft'});

    $t->get_ok('/tenant-storefront')
      ->status_is(200)
      ->content_like(qr/Coming Soon/, 'an empty storefront says Coming Soon')
      ->content_like(qr/No programs currently available/,
          'and explains what that means')
      ->content_unlike(qr/Wheel Art Camp/,
          'and does not list the unpublished programme');

    $dao->db->query(q{UPDATE projects SET status = 'published'});
};

done_testing;
