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

# Create test data
my $school1 = Test::Registry::Fixtures::create_location($db, {
    name => 'Lincoln Elementary School',
    slug => 'lincoln-elementary',
    description => 'A great school for learning',
    address_street => '123 School St',
    address_city => 'Test City',
    address_state => 'TS',
    address_zip => '12345',
    capacity => 100,
});

my $school2 = Test::Registry::Fixtures::create_location($db, {
    name => 'Washington Middle School',
    slug => 'washington-middle',
});

my $program1 = Test::Registry::Fixtures::create_project($db, {
    name => 'After School Arts',
    description => 'Creative arts program for students',
});

my $program2 = Test::Registry::Fixtures::create_project($db, {
    name => 'STEM Club',
    description => 'Science, Technology, Engineering, and Math activities',
});

# Create sessions
my $active_session = Test::Registry::Fixtures::create_session($db, {
    name => 'Spring 2024',
    start_date => '2024-03-01',
    end_date => '2024-05-31',
    status => 'published',
});

my $draft_session = Test::Registry::Fixtures::create_session($db, {
    name => 'Summer 2024',
    status => 'draft',
});

my $closed_session = Test::Registry::Fixtures::create_session($db, {
    name => 'Winter 2023',
    status => 'closed',
});

# Create events
my $event1 = Test::Registry::Fixtures::create_event($db, {
    location_id => $school1->id,
    project_id => $program1->id,
    capacity => 20,
});

my $event2 = Test::Registry::Fixtures::create_event($db, {
    location_id => $school1->id,
    project_id => $program2->id,
    capacity => 15,
});

my $event3 = Test::Registry::Fixtures::create_event($db, {
    location_id => $school2->id,  # Different school
    project_id => $program1->id,
    capacity => 25,
});

# Add events to sessions
$active_session->add_events($db, $event1->id, $event2->id);
$draft_session->add_events($db, $event1->id);
$closed_session->add_events($db, $event2->id);

# Add pricing
Registry::DAO::PricingPlan->create($db, {
    session_id => $active_session->id,
    plan_name => 'Standard',
    plan_type => 'standard',
    amount => 150.00,
});

Registry::DAO::PricingPlan->create($db, {
    session_id => $active_session->id,
    plan_name => 'Early Bird',
    plan_type => 'early_bird',
    amount => 120.00,
    requirements => { early_bird_cutoff_date => '2024-02-15' }
});

# Create some enrollments
my $student1 = Test::Registry::Fixtures::create_user($db, {
    name => 'Student One',
    email => 'student1\@test.com',
});

Registry::DAO::Enrollment->create($db, {
    session_id => $active_session->id,
    student_id => $student1->id,
    status => 'active',
});

subtest 'Show school page' => sub {
    $t->get_ok('/school/lincoln-elementary')
      ->status_is(200)
      ->element_exists('h1', 'Has page title')
      ->text_is('h1', 'Lincoln Elementary School', 'Correct school name')
      ->content_like(qr/123 School St/, 'Shows address')
      ->content_like(qr/Test City, TS 12345/, 'Shows city, state, zip')
      ->content_like(qr/A great school for learning/, 'Shows description');
};

subtest 'No authentication required' => sub {
    # Ensure we're not logged in
    $t->reset_session;
    
    $t->get_ok('/school/lincoln-elementary')
      ->status_is(200, 'Public access allowed');
};

subtest 'Shows only published sessions' => sub {
    $t->get_ok('/school/lincoln-elementary')
      ->status_is(200)
      ->content_like(qr/Spring 2024/, 'Shows published session')
      ->content_unlike(qr/Summer 2024/, 'Does not show draft session')
      ->content_unlike(qr/Winter 2023/, 'Does not show closed session');
};

subtest 'Groups by program' => sub {
    $t->get_ok('/school/lincoln-elementary')
      ->status_is(200)
      ->element_exists('.program-card', 'Has program cards')
      ->content_like(qr/After School Arts/, 'Shows program 1')
      ->content_like(qr/STEM Club/, 'Shows program 2')
      ->content_like(qr/Creative arts program/, 'Shows program description');
};

subtest 'Shows enrollment status' => sub {
    $t->get_ok('/school/lincoln-elementary')
      ->status_is(200)
      ->content_like(qr/19 spots available/, 'Shows available spots for event 1')
      ->content_like(qr/15 spots available/, 'Shows available spots for event 2');
};

subtest 'Shows pricing information' => sub {
    $t->get_ok('/school/lincoln-elementary')
      ->status_is(200)
      ->content_like(qr/Starting at:.*\$120\.00/s, 'Shows best price');
};

subtest 'Enrollment buttons' => sub {
    $t->get_ok('/school/lincoln-elementary')
      ->status_is(200)
      ->element_exists('a[href*="summer-camp-registration"]', 'Has enrollment link')
      ->text_like('a[href*="summer-camp-registration"]', qr/Enroll Now/, 'Shows enroll button');
};

subtest 'Full session handling' => sub {
    # Fill up event2
    for my $i (2..15) {
        my $student = Test::Registry::Fixtures::create_user($db, {
            name => "Student $i",
            email => "student$i\@test.com",
        });
        Registry::DAO::Enrollment->create($db, {
            session_id => $active_session->id,
            student_id => $student->id,
            status => 'active',
        });
    }
    
    $t->get_ok('/school/lincoln-elementary')
      ->status_is(200)
      ->content_like(qr/Full/, 'Shows full status')
      ->content_like(qr/Join Waitlist/, 'Shows waitlist button for full session');
};

subtest 'School not found' => sub {
    $t->get_ok('/school/nonexistent-school')
      ->status_is(404)
      ->content_like(qr/School not found/);
};

subtest 'No programs available' => sub {
    my $empty_school = Test::Registry::Fixtures::create_location($db, {
        name => 'Empty School',
        slug => 'empty-school',
    });
    
    $t->get_ok('/school/empty-school')
      ->status_is(200)
      ->content_like(qr/No programs are currently available/);
};

subtest 'Mobile responsive' => sub {
    $t->get_ok('/school/lincoln-elementary')
      ->status_is(200)
      ->element_exists('.container', 'Has responsive container')
      ->element_exists('.grid', 'Has responsive grid');
};

subtest 'Tenant isolation' => sub {
    # Create another tenant
    $db->schema('registry');
    my $other_tenant = Test::Registry::Fixtures::create_tenant($db, {
        name => 'Other District',
        slug => 'other-district',
    });
    
    # Create location in other tenant
    $db->schema($other_tenant->slug);
    my $other_school = Test::Registry::Fixtures::create_location($db, {
        name => 'Other School',
        slug => 'lincoln-elementary', # Same slug
    });
    
    # Switch back to original tenant
    $db->schema($tenant->slug);
    
    # Should still see original school
    $t->get_ok('/school/lincoln-elementary')
      ->status_is(200)
      ->text_is('h1', 'Lincoln Elementary School', 'Shows correct tenant school');
};

done_testing;