use 5.38.0;
use lib          qw(lib t/lib);
use experimental qw(defer builtin);
use builtin      qw(blessed);

use Test::Mojo;
use Test::More import => [qw( done_testing is )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB qw(DAO Workflow WorkflowRun WorkflowStep);
my $dao = Registry::DAO->new( url => Test::Registry::DB->new_test_db() );

$ENV{DB_URL} = $dao->url;

our $user = $dao->create(
    User => {
        username => 'JohnnyTest',
    }
);
our $location = $dao->create(
    Location => {
        name => 'Event Venue',
    }
);
our $project = $dao->create(
    Project => {
        name => 'Event Curriculum',
    }
);

{

    my sub workflow_url ($workflow) {
        return sprintf '/%s', $workflow->slug;
    }

    my sub workflow_start_url ( $workflow, $step ) {
        return sprintf '/%s/%s', $workflow->slug, $step->slug;
    }

    my sub workflow_run_step_url ( $workflow, $run, $step ) {
        return sprintf '/%s/%s/%s', $workflow->slug, $run->id, $step->slug;
    }

    my sub workflow_process_step_url ( $workflow, $run, $step ) {
        return sprintf '/%s/%s/%s', $workflow->slug, $run->id, $step->slug;
    }

    my $t = Test::Mojo->new('Registry');

    my $workflow   = $dao->find( Workflow => { slug => 'event-creation' } );
    my $first_step = $workflow->first_step( $dao->db );

    # grab the url from the form action so we can post to it
    my $next_url =
      $t->get_ok( workflow_url($workflow) )->status_is(200)
      ->element_exists( sprintf 'form[action="%s"]',
        workflow_start_url( $workflow, $first_step ) )
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
            time        => '2021-12-31',
            teacher_id  => $user->id,
            location_id => $location->id,
            project_id  => $project->id,
        }
    )->status_is(302)->header_like( Location => qr/complete$/ )
      ->tx->res->headers->location;

    # refresh the run
    ($run) = $dao->find( WorkflowRun => { id => $run->id } );

    is $run->data()->{'info'}{time}, '2021-12-31', 'run data time is updated';
    is $run->data()->{'info'}{teacher_id}, $user->id,
      'run data user_id is updated';

    # post to the final step which saves everything
    $t->post_ok( $next_url => form => {} )->status_is(201);

    # now check to see if the event was created
    my $event = $dao->find(
        Event => {
            time        => $run->data()->{'info'}{time},
            location_id => $location->id
        }
    );

    die 'Event not created' unless $event;
    is $event->location( $dao->db )->name, 'Event Venue', 'Event Venue correct';
    is $event->teacher( $dao->db )->username, 'JohnnyTest',
}
