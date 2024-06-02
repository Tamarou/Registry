use 5.38.0;
use lib          qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw( done_testing is ok )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB qw(DAO Workflow WorkflowRun WorkflowStep);
my $dao = Registry::DAO->new( url => Test::Registry::DB->new_test_db() );

{    # basics
    my $workflow = $dao->create(
        Workflow => {
            slug        => 'test',
            name        => 'Test Workflow',
            description => 'A test workflow',
        }
    );

    my ($test) = $dao->find( Workflow => { slug => 'test' } );
    is $test->id, $workflow->id,       'find returns the correct workflow';
    is $workflow->runs( $dao->db ), 0, 'no runs for the workflow yet';
    is $workflow->first_step( $dao->db )->slug, 'landing',
      'the first step is landing';

    my $run = $workflow->new_run( $dao->db );
    is $workflow->runs( $dao->db ), 1, 'one run for the workflow now';
    is $workflow->latest_run( $dao->db )->id, $run->id,
      'uatest run is the one we just created';

    ok $run->process( $dao->db, $run->next_step( $dao->db ), { count => 1 } );
    is $run->data()->{count}, 1, 'run data is updated';
}

{
    # user registration
    my $workflow = $dao->create(
        Workflow => {
            slug => 'signup',
            name => "Customer Registration",
        }
    );

    $workflow->add_step(
        $dao->db,
        {
            slug        => 'userinfo',
            description => 'Customer Info',
        }
    );

    $workflow->add_step(
        $dao->db,
        {
            slug        => 'done',
            description => 'Registration Complete',
        }
    );

    is $workflow->first_step( $dao->db )->slug, 'landing',
      'first step is landing';
    is $workflow->last_step( $dao->db )->slug, 'done', 'last step is done';

    my $run = $workflow->new_run( $dao->db );
    is $run->next_step( $dao->db )->slug, 'landing', 'next step is landing';
    is $run->latest_step( $dao->db ),     undef,     'no latest step yet';

    is keys $run->data->%*, 0, 'no data yet';
    ok $run->process( $dao->db, $run->next_step( $dao->db ), {} ),
      'process landing page';
    is $run->latest_step( $dao->db )->slug, 'landing', 'latest step is landing';
    is $run->next_step( $dao->db )->slug,   'userinfo', 'next step is userinfo';

    my $step = $run->next_step( $dao->db );
    is $step->slug, 'userinfo', 'step is userinfo';
    $run->process( $dao->db, $step, { name => 'Test User' } );

    $step = $run->next_step( $dao->db );
    is $step->slug, 'done', 'next step is done';
    $run->process( $dao->db, $step );
    is $run->next_step( $dao->db ), undef,       'Next step is correct';
    is $run->data->{name},          'Test User', 'run data is updated';

}

