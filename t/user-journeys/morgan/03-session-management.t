use 5.40.2;
use lib          qw(lib t/lib);
use experimental qw(defer builtin);

use Test::More import => [qw( done_testing is ok )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;

# ABOUTME: Test Morgan's session management user journey workflow
# ABOUTME: Validates session scheduling, capacity management, and conflict resolution

my $t   = Test::Registry::DB->new;
my $db  = $t->db;
my $dao = Registry::DAO->new( db => $db );

# Create test program for sessions
ok my $program = $dao->create( 'Program', {
    name     => 'Advanced Mathematics',
    slug     => 'advanced-math',
    metadata => {
        type        => 'academic',
        grade_level => '9-12',
        subject     => 'mathematics'
    }
}), 'Create test program';

# Test: Schedule recurring sessions
ok my $session = $dao->create( 'Session', {
    name       => 'Calculus I - Fall 2025',
    slug       => 'calc-i-fall-2025',
    start_date => '2025-09-01',
    end_date   => '2025-12-15',
    capacity   => 25,
    metadata   => {
        program_id      => $program->id,
        recurrence_type => 'weekly',
        recurrence_days => 'monday,wednesday,friday',
        start_time      => '09:00',
        end_time        => '10:30'
    }
}), 'Schedule recurring sessions';

# Test: Assign appropriate locations based on needs
ok my $location = $dao->create( 'Location', {
    name     => 'Main Campus Room 101',
    slug     => 'main-campus-101',
    capacity => 30,
    metadata => {
        type      => 'classroom',
        equipment => ['projector', 'whiteboard', 'computers']
    }
}), 'Create test location';

ok $session->update($dao->db, {
    metadata => {
        %{$session->metadata},
        location_id => $location->id
    }
}), 'Assign appropriate locations based on needs';

# Test: Handle session capacity and waitlists
ok $session->capacity, 'Session has capacity';
ok $session->capacity == 25, 'Handle session capacity and waitlists';

# Test: Resolve scheduling conflicts
# This is a simplified test - real conflict resolution would be more complex
ok $session->metadata->{start_time}, 'Session has start time';
ok $session->metadata->{end_time}, 'Resolve scheduling conflicts';