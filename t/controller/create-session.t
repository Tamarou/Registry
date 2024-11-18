use 5.40.0;
use lib          qw(lib t/lib);
use experimental qw(defer builtin);

use Test::Mojo;
use Test::More import => [qw( done_testing is like ok )];
defer { done_testing };

use Registry::DAO ();
use Test::Registry::DB ();
use Test::Registry::Helpers qw(
    workflow_url
    workflow_run_step_url
    workflow_process_step_url
);

my $dao = Registry::DAO->new( url => Test::Registry::DB->new_test_db() );

$ENV{DB_URL} = $dao->url;

my $event = $dao->create(
    Event => {
        time        => '2021-12-31',
        teacher_id  => $dao->create( User => { username => 'JohnnyTest' } )->id,
        location_id =>
          $dao->create( Location => { name => 'Event Venue' } )->id,
        project_id =>
          $dao->create( Project => { name => 'Event Curriculum' } )->id,
    }
);

{
    my $t = Test::Mojo->new('Registry');

    my ($workflow) = $dao->find( Workflow => { slug => 'session-creation' } );
    my $first_step = $workflow->first_step( $dao->db );

    # grab the url from the form action so we can post to it
    my $next_url =
      $t->get_ok( workflow_url($workflow) )->status_is(200)
      ->element_exists('form[action="/session-creation"]')
      ->tx->res->dom->at('form[action]')->{action};

    $next_url =
      $t->post_ok( $next_url => form => {} )->status_is(302)
      ->header_like( Location => qr/info$/ )->tx->res->headers->location;

    # check that the workflow run was created
    is $workflow->runs( $dao->db ), 1, 'we have one run';
    is $next_url,
      workflow_run_step_url(
        $workflow,
        $workflow->latest_run( $dao->db ),
        $workflow->latest_run( $dao->db )->next_step( $dao->db )
      ),
      'current step url is correct';

    # grab a copy of the run
    my $run = $workflow->latest_run( $dao->db );

    $next_url = $t->get_ok($next_url)->status_is(200)->element_exists(
        sprintf 'form[action="%s"]',
        workflow_process_step_url(
            $workflow, $run, $run->next_step( $dao->db )
        )
    )->tx->res->dom->at('form[action]')->{action};

    # check the run again
    is $workflow->runs( $dao->db ), 1, 'we have one run';
    is $next_url,
      workflow_process_step_url( $workflow, $run, $run->next_step( $dao->db ) ),
      'current step url is correct';

    is $next_url,
      workflow_process_step_url( $workflow, $run, $run->next_step( $dao->db ) ),
      'current step url is correct for the cached run';

    $next_url = $t->post_ok(
        $next_url => form => {
            name   => 'Session 1',
            events => [ $event->id ]
        }
    )->status_is(302)->header_like( Location => qr/complete$/ )
      ->tx->res->headers->location;

    $next_url =
      $t->get_ok($next_url)->status_is(200)->element_exists('form[action]')
      ->tx->res->dom->at('form[action]')->{action};

    ($run) = $dao->find( WorkflowRun => { id => $run->id } );
    ok !$run->completed( $dao->db ), 'run is not completed';

    is $run->data()->{name},   'Session 1', 'run data name is updated';
    is $run->data()->{events}, $event->id,  'run data events are updated';

    # post to the final step which saves everything
    $t->post_ok( $next_url => form => {} )->status_is(201);
    ($run) = $dao->find( WorkflowRun => { id => $run->id } );
    ok $run->completed( $dao->db ), 'run is completed';

    # now check to see if the session was created
    my $session = $dao->find( Session => { slug => 'session-1', } );

    die 'Session not created' unless $session;
    is $session->name, 'Session 1', 'Session name is correct';
    my @events = $session->events( $dao->db );
    is scalar @events, 1,          'Session has one event';
    is $events[0]->id, $event->id, 'Event Venue correct';
}

{
    my $t          = Test::Mojo->new('Registry');
    my ($workflow) = $dao->find( Workflow => { slug => 'session-creation' } );
    my $first_step = $workflow->first_step( $dao->db );
    my $next_url =
      $t->get_ok( workflow_url($workflow) )->status_is(200)
      ->element_exists('form[action="/session-creation"]')
      ->tx->res->dom->at('form[action]')->{action};

    $next_url =
      $t->post_ok( $next_url => form => {} )->status_is(302)
      ->header_like( Location => qr/info$/ )->tx->res->headers->location;

    my ($run) = $workflow->latest_run( $dao->db );
    my $id = $run->id;
    like $next_url, qr/$id/, 'url looks like it has the the run id';

    # save the DOM so we can check if we were redirected from the event creation
    my $dom =
      $t->get_ok($next_url)->status_is(200)
      ->element_exists('a[rel="create-page event"]')->tx->res->dom;

    my $continuation = $dom->at('a[rel="create-page event"]')->{href};

    my $events_link =
      $t->post_ok($continuation)->status_is(302)
      ->header_like( Location => qr/^\/event-creation/ )
      ->tx->res->headers->location;

    my $event_next_action =
      $t->get_ok($events_link)->status_is(200)->element_exists('form[action]')
      ->tx->res->dom->at('form[action]')->{action};
    my $location = $dao->create(
        Location => {
            name => 'Location ' . $$,
        }
    );
    my $event_next = $t->post_ok(
        $event_next_action => form => {
            time       => '2021-12-31',
            teacher_id => $dao->create(
                User => {
                    username => 'JohnnyTest' . $$,
                }
            )->id,
            location_id => $location->id,
            project_id  => $event->project( $dao->db )->id,
        }
    )->status_is(302)->header_like( Location => qr/complete$/ )
      ->tx->res->headers->location;

    $event_next_action =
      $t->get_ok($event_next)->status_is(200)->element_exists('form[action]')
      ->tx->res->dom->at('form[action]')->{action};

    $next_url = $t->post_ok( $event_next_action => form => {} )->status_is(302)
      ->header_is( Location => $next_url )->tx->res->headers->location;

    is $next_url, $dom->at('form[action]')->{action},
      'we are back at session creation';

    $next_url = $t->post_ok(
        $next_url => form => {
            name => 'Session 2',
        }
    )->status_is(302)->header_like( Location => qr/complete$/ )
      ->tx->res->headers->location;

    ($run) = $dao->find( WorkflowRun => { id => $id } );
    is $run->data()->{name}, 'Session 2', 'run data name is Session 2';

    $next_url = $next_url =
      $t->get_ok($next_url)->status_is(200)->element_exists('form[action]')
      ->tx->res->dom->at('form[action]')->{action};

    my $event2 = $dao->find(
        Event => { time => '2021-12-31', location_id => $location->id } );
    is $run->data()->{events}->[0], $event2->id, 'run data events are updated';

    is $run->data()->{name}, 'Session 2', 'run data name is updated';

    # post to the final step which saves everything
    $t->post_ok( $next_url => form => {} )->status_is(201);
    ($run) = $dao->find( WorkflowRun => { id => $id } );
    ok $run->completed( $dao->db ), 'run is completed';

    # now check to see if the session was created
    my $session = $dao->find( Session => { slug => 'session-2', } );

    die 'Session not created' unless $session;
    is $session->name, 'Session 2', 'Session name is correct';
    my @events = $session->events( $dao->db );
    is scalar @events, 1,           'Session has one event';
    is $events[0]->id, $event2->id, 'Event Venue correct';
}
