#!/usr/bin/env perl
use v5.34.0;
use warnings;
use utf8;
use experimental qw(signatures);

use Test::More;
use Test::Mojo;

use lib qw(lib t/lib);
use Test::Registry::DB;
use Test::Registry::Fixtures;

use Registry;
use Registry::DAO::Event;
use Registry::DAO::PricingPlan;
use Registry::DAO::ProgramType;

# Setup test database
my $t_db = Test::Registry::DB->new;
my $db = $t_db->db;

# Create test app
my $t = Test::Mojo->new('Registry');
$t->app->helper(dao => sub { $db });

# Create test tenant
my $tenant = Test::Registry::Fixtures::create_tenant($db, {
    name => 'Test School District',
    slug => 'test-district',
});

# Switch to tenant schema
$db->schema($tenant->slug);

# Create test location
my $school = Test::Registry::Fixtures::create_location($db, {
    name => 'Test Elementary School',
    slug => 'test-elementary',
});

# Create programs with different types
my $afterschool = Test::Registry::Fixtures::create_project($db, {
    name => 'After School Arts',
    program_type_slug => 'afterschool',
});

my $summer = Test::Registry::Fixtures::create_project($db, {
    name => 'Summer Science Camp',
    program_type_slug => 'summer-camp',
});

# Create sessions with different dates
my $current_session = Test::Registry::Fixtures::create_session($db, {
    name => 'Current Session',
    start_date => '2024-03-01',
    end_date => '2024-05-31',
    status => 'published',
});

my $future_session = Test::Registry::Fixtures::create_session($db, {
    name => 'Future Session',
    start_date => '2024-09-01',
    end_date => '2024-12-31',
    status => 'published',
});

# Create events with age ranges
my $young_event = Test::Registry::Fixtures::create_event($db, {
    location_id => $school->id,
    project_id => $afterschool->id,
    min_age => 5,
    max_age => 8,
    capacity => 20,
});

my $older_event = Test::Registry::Fixtures::create_event($db, {
    location_id => $school->id,
    project_id => $summer->id,
    min_age => 9,
    max_age => 12,
    capacity => 15,
});

# Add events to sessions
$current_session->add_events($db, $young_event->id);
$future_session->add_events($db, $older_event->id);

# Add pricing with early bird
Registry::DAO::PricingPlan->create($db, {
    session_id => $current_session->id,
    plan_name => 'Standard',
    plan_type => 'standard',
    amount => 200.00,
});

Registry::DAO::PricingPlan->create($db, {
    session_id => $current_session->id,
    plan_name => 'Early Bird',
    plan_type => 'early_bird',
    amount => 150.00,
    requirements => { early_bird_cutoff_date => '2025-12-31' } # Future date
});

# Create enrollments to test fill indicators
for my $i (1..16) {
    my $student = Test::Registry::Fixtures::create_user($db, {
        name => "Student $i",
        email => "student$i\@test.com",
    });
    Registry::DAO::Enrollment->create($db, {
        session_id => $current_session->id,
        student_id => $student->id,
        status => 'active',
    });
}

subtest 'Age filtering' => sub {
    # Filter for young children
    $t->get_ok('/school/test-elementary?min_age=5&max_age=8')
      ->status_is(200)
      ->content_like(qr/After School Arts/, 'Shows program for young age range')
      ->content_unlike(qr/Summer Science Camp/, 'Does not show program for older age range');
    
    # Filter for older children
    $t->get_ok('/school/test-elementary?min_age=9&max_age=12')
      ->status_is(200)
      ->content_unlike(qr/After School Arts/, 'Does not show program for young age range')
      ->content_like(qr/Summer Science Camp/, 'Shows program for older age range');
};

subtest 'Start date filtering' => sub {
    # Filter for sessions starting after June
    $t->get_ok('/school/test-elementary?start_date=2024-06-01')
      ->status_is(200)
      ->content_unlike(qr/Current Session/, 'Does not show session starting before filter date')
      ->content_like(qr/Future Session/, 'Shows session starting after filter date');
};

subtest 'Program type filtering' => sub {
    # Filter for afterschool programs
    $t->get_ok('/school/test-elementary?program_type=afterschool')
      ->status_is(200)
      ->content_like(qr/After School Arts/, 'Shows afterschool program')
      ->content_unlike(qr/Summer Science Camp/, 'Does not show summer camp');
    
    # Filter for summer camps
    $t->get_ok('/school/test-elementary?program_type=summer-camp')
      ->status_is(200)
      ->content_unlike(qr/After School Arts/, 'Does not show afterschool program')
      ->content_like(qr/Summer Science Camp/, 'Shows summer camp');
};

subtest 'Visual indicators - filling up' => sub {
    $t->get_ok('/school/test-elementary')
      ->status_is(200)
      ->element_exists('.filling-up', 'Has filling up indicator')
      ->content_like(qr/Filling Fast.*4 left/, 'Shows filling fast with spots left');
};

subtest 'Visual indicators - early bird' => sub {
    $t->get_ok('/school/test-elementary')
      ->status_is(200)
      ->element_exists('.early-bird-notice', 'Has early bird notice')
      ->content_like(qr/Early Bird Special.*\$150\.00/, 'Shows early bird price')
      ->content_like(qr/expires 2025-12-31/, 'Shows early bird expiration');
};

subtest 'Visual indicators - waitlist' => sub {
    # Add waitlist entries
    for my $i (1..3) {
        my $student = Test::Registry::Fixtures::create_user($db, {
            name => "Waitlist Student $i",
            email => "waitlist$i\@test.com",
        });
        Registry::DAO::Waitlist->join_waitlist(
            $db,
            $current_session->id,
            $school->id,
            $student->id,
            $student->id  # Parent same as student for simplicity
        );
    }
    
    $t->get_ok('/school/test-elementary')
      ->status_is(200)
      ->content_like(qr/3 waiting/, 'Shows waitlist count');
};

subtest 'HTMX filtering' => sub {
    # Test HTMX request returns only programs section
    $t->get_ok('/school/test-elementary?min_age=5' => {'HX-Request' => 'true'})
      ->status_is(200)
      ->element_exists('h2', 'Has programs heading')
      ->element_exists_not('header', 'Does not include page header')
      ->element_exists_not('#filter-form', 'Does not include filter form');
};

subtest 'Combined filters' => sub {
    # Create a new session that matches all filters
    my $match_session = Test::Registry::Fixtures::create_session($db, {
        name => 'Perfect Match',
        start_date => '2024-10-01',
        status => 'published',
    });
    
    my $match_event = Test::Registry::Fixtures::create_event($db, {
        location_id => $school->id,
        project_id => $afterschool->id,
        min_age => 6,
        max_age => 10,
    });
    
    $match_session->add_events($db, $match_event->id);
    
    # Apply multiple filters
    $t->get_ok('/school/test-elementary?min_age=7&max_age=9&start_date=2024-09-15&program_type=afterschool')
      ->status_is(200)
      ->content_like(qr/Perfect Match/, 'Shows session matching all filters')
      ->content_unlike(qr/Current Session/, 'Filters out non-matching sessions')
      ->content_unlike(qr/Future Session/, 'Filters out non-matching sessions');
};

subtest 'No results message' => sub {
    # Use filters that match nothing
    $t->get_ok('/school/test-elementary?min_age=18')
      ->status_is(200)
      ->content_like(qr/No programs match your criteria/, 'Shows no results message')
      ->content_like(qr/Try adjusting your filters/, 'Shows helpful suggestion');
};

subtest 'Filter persistence' => sub {
    # Check that filter values are preserved in form
    $t->get_ok('/school/test-elementary?min_age=7&program_type=afterschool')
      ->status_is(200)
      ->element_exists('input[name="min_age"][value="7"]', 'Min age value preserved')
      ->element_exists('option[value="afterschool"][selected]', 'Program type selection preserved');
};

done_testing;