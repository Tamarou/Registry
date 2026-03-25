use 5.42.0;
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
    # WorkflowRun::save() must correctly persist JSONB data
    my $workflow = $dao->create(
        Workflow => {
            slug        => 'save-test',
            name        => 'Save Test Workflow',
            description => 'Tests the save method',
        }
    );

    $workflow->add_step(
        $dao,
        {
            slug        => 'landing',
            description => 'Landing Page',
        }
    );

    my $run = $workflow->new_run( $dao->db );
    $run->process( $dao->db, $run->next_step( $dao->db ), { foo => 'bar' } );

    # Mutate the in-memory data directly via update_data, adding a key
    # that only save() would persist (not already in DB from process).
    $run->update_data( $dao->db, { extra => 'via_update_data' } );

    # Now use save() to persist latest_step_id along with data.
    # Before the fix, save() silently failed because it passed a
    # hashref to SQL::Abstract without {-json => ...} wrapping,
    # causing SQL::Abstract to interpret hash keys as column names.
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    my $saved = $run->save( $dao->db );
    is scalar @warnings, 0,
      'save() produces no warnings (no silent JSONB encoding failure)';
    ok $saved, 'save() returns a truthy value';

    # Reload from DB and verify the full round-trip
    my ($reloaded) = $dao->find( WorkflowRun => { id => $run->id } );
    is $reloaded->data->{foo}, 'bar',
      'save() preserves original process() data';
    is $reloaded->data->{extra}, 'via_update_data',
      'save() preserves data from update_data';
}
