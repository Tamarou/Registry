use 5.40.2;
use lib          qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw( done_testing is ok )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;
my $test_db = Test::Registry::DB->new();
my $dao = $test_db->db;

{    # basics
    my $workflow = $dao->create(
        Workflow => {
            slug        => 'test',
            name        => 'Test Workflow',
            description => 'A test workflow',
        }
    );

    $workflow->add_step(
        $dao,
        {
            slug        => 'landing',
            description => 'Landing Page',
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
        $dao,
        {
            slug        => 'landing',
            description => 'Landing Page',
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

{
    # async workflow processing
    my $workflow = $dao->create(
        Workflow => {
            slug => 'async-test',
            name => "Async Test Workflow",
        }
    );

    $workflow->add_step(
        $dao, { slug => 'start', description => 'Start step' }
    );
    $workflow->add_step(
        $dao,
        {
            slug        => 'middle',
            description => 'Middle step',
            depends_on  => $workflow->first_step( $dao->db )->id
        }
    );

    my $run = $workflow->new_run( $dao->db );

    # Test async processing
    my $result = $run->process_async( $dao->db, $run->next_step( $dao->db ), { async_data => 'test' } )->wait;
    ok $result, 'Async processing completed';
    is $result->{async_data}, 'test', 'Async data passed through';

    # Verify state after async processing
    is $run->latest_step( $dao->db )->slug, 'start', 'Latest step updated after async processing';
    is $run->next_step( $dao->db )->slug, 'middle', 'Next step is correct after async';

    # Test chaining async operations
    $result = $run->process_async( $dao->db, $run->next_step( $dao->db ), { chained => 1 } )->wait;
    is $result->{chained}, 1, 'Chained async operation completed';
}

{
    # async step processing
    my $workflow = $dao->create(
        Workflow => {
            slug => 'async-step-test',
            name => "Async Step Test",
        }
    );

    my $step = $workflow->add_step(
        $dao, { slug => 'async-step', description => 'Async test step' }
    );

    # Test async step processing directly
    my $result = $step->process_async( $dao->db, { step_data => 'value' } )->wait;
    ok $result, 'Async step processing returned result';
    is $result->{step_data}, 'value', 'Async step data preserved';
}
