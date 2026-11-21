# ABOUTME: Morgan (program administrator) user journey test for session management.
# ABOUTME: Drives the session-creation workflow via HTTP to schedule sessions with events.
use 5.42.0;
use lib          qw(lib t/lib);
use experimental qw(defer);

use Test::Registry::Mojo;
use Mojo::Home;
use Test::More import => [qw( done_testing is ok )];
defer { done_testing };

use Registry::DAO           qw(Workflow);
use Test::Registry::DB      ();
use Test::Registry::Helpers qw(
  workflow_url
  workflow_run_step_url
  workflow_process_step_url
);
use YAML::XS qw(Load);

my $test_db = Test::Registry::DB->new();
my $dao     = $test_db->db;

$ENV{DB_URL} = $test_db->uri;

# Import all non-draft workflows
my @files =
  Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;
for my $file (@files) {
    next if Load( $file->slurp )->{draft};
    Workflow->from_yaml( $dao, $file->slurp );
}

# Prerequisite data shared across journey blocks
my $location = $dao->create(
    Location => {
        name => 'Riverside Elementary',
    }
);

my $teacher = $dao->create(
    User => {
        username => 'session.teacher',
    }
);

my $project = $dao->create(
    Project => {
        name => 'STEM Program',
    }
);

# Create an event to attach to the session
my $event = $dao->create(
    Event => {
        time        => '2024-09-09',
        teacher_id  => $teacher->id,
        location_id => $location->id,
        project_id  => $project->id,
    }
);

{    # Journey: Schedule a session with a recurring event via the session-creation workflow
    my $t = Test::Registry::Mojo->new('Registry');

    my ($workflow) = $dao->find( Workflow => { slug => 'session-creation' } );
    ok $workflow, 'session-creation workflow found';

    # Start the workflow run
    my $next_url =
      $t->get_ok( workflow_url($workflow) )->status_is(200)
      ->element_exists('form[action="/session-creation"]')
      ->tx->res->dom->at('form[action]')->{action};

    $next_url =
      $t->post_ok( $next_url => form => {} )->status_is(302)
      ->header_like( Location => qr/info$/ )->tx->res->headers->location;

    my $run = $workflow->latest_run( $dao->db );
    ok $run, 'workflow run created';

    # Fill in session info with an event
    $next_url =
      $t->get_ok($next_url)->status_is(200)
      ->element_exists('form[action]')
      ->tx->res->dom->at('form[action]')->{action};

    $next_url = $t->post_ok(
        $next_url => form => {
            name   => 'STEM Fall 2024',
            events => [ $event->id ],
        }
    )->status_is(302)->header_like( Location => qr/complete$/ )
      ->tx->res->headers->location;

    # Confirm the session creation on the complete step
    $next_url =
      $t->get_ok($next_url)->status_is(200)
      ->element_exists('form[action]')
      ->tx->res->dom->at('form[action]')->{action};

    $t->post_ok( $next_url => form => {} )->status_is(201);

    ($run) = $dao->find( WorkflowRun => { id => $run->id } );
    ok $run->completed( $dao->db ), 'workflow run is completed';

    my ($session) = $dao->find( Session => { slug => 'stem-fall-2024' } );
    ok $session, 'session created in database';
    is $session->name, 'STEM Fall 2024', 'session name is correct';

    my @events = $session->events( $dao->db );
    is scalar @events, 1, 'session has one event';
    is $events[0]->id, $event->id, 'event is correctly linked to session';
}

{    # Journey: Assign a location-appropriate event to the session
    my $location2 = $dao->create(
        Location => {
            name => 'Valley Middle School Computer Lab',
        }
    );

    my $event2 = $dao->create(
        Event => {
            time        => '2024-09-16',
            teacher_id  => $teacher->id,
            location_id => $location2->id,
            project_id  => $project->id,
        }
    );

    my $t = Test::Registry::Mojo->new('Registry');

    my ($workflow) = $dao->find( Workflow => { slug => 'session-creation' } );

    my $next_url =
      $t->get_ok( workflow_url($workflow) )->status_is(200)
      ->tx->res->dom->at('form[action]')->{action};

    $next_url =
      $t->post_ok( $next_url => form => {} )->status_is(302)
      ->tx->res->headers->location;

    my $run = $workflow->latest_run( $dao->db );

    $next_url =
      $t->get_ok($next_url)->status_is(200)
      ->element_exists('form[action]')
      ->tx->res->dom->at('form[action]')->{action};

    $next_url = $t->post_ok(
        $next_url => form => {
            name   => 'Arts Fall 2024',
            events => [ $event2->id ],
        }
    )->status_is(302)->tx->res->headers->location;

    $next_url =
      $t->get_ok($next_url)->status_is(200)
      ->element_exists('form[action]')
      ->tx->res->dom->at('form[action]')->{action};

    $t->post_ok( $next_url => form => {} )->status_is(201);

    my ($session) = $dao->find( Session => { slug => 'arts-fall-2024' } );
    ok $session, 'location-appropriate session created';

    my @events = $session->events( $dao->db );
    ok @events, 'session has events';
    is $events[0]->location( $dao->db )->name, 'Valley Middle School Computer Lab',
      'session event is at the correct location';
}

{    # Journey: Set session capacity via metadata
    my ($session) = $dao->find( Session => { slug => 'stem-fall-2024' } );
    ok $session, 'session found for capacity update';

    $session->update(
        $dao->db,
        { capacity => 20 }
    );

    my ($updated) = $dao->find( Session => { id => $session->id } );
    is $updated->capacity, 20, 'session capacity set to 20';
}

{    # Journey: Verify sessions do not share events (no scheduling conflicts)
    my ($session1) = $dao->find( Session => { slug => 'stem-fall-2024' } );
    my ($session2) = $dao->find( Session => { slug => 'arts-fall-2024' } );

    ok $session1, 'first session found';
    ok $session2, 'second session found';

    my @events1 = $session1->events( $dao->db );
    my @events2 = $session2->events( $dao->db );

    my %event_ids1 = map { $_->id => 1 } @events1;

    my $overlap = grep { $event_ids1{ $_->id } } @events2;
    is $overlap, 0, 'sessions share no events - no scheduling conflict';
}
