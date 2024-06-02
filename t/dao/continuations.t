use 5.38.0;
use lib          qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw( done_testing is )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB qw(DAO Workflow WorkflowRun WorkflowStep);
my $dao = Registry::DAO->new( url => Test::Registry::DB->new_test_db() );

{
    # continuations
    my $parent = $dao->create(
        Workflow => {
            slug => 'continuations',
            name => "Continuations",
        }
    );

    $parent->add_step(
        $dao->db,
        {
            slug        => 'done',
            description => 'Parent Workflow Complete',
        }
    );

    my $child = $dao->create(
        Workflow => {
            slug => 'child',
            name => "Child Workflow",
        }
    );

    $child->add_step(
        $dao->db,
        {
            slug        => 'done',
            description => 'Child Workflow Complete',
        }
    );

    my $parent_run = $parent->new_run( $dao->db, );
    $parent_run->process(
        $dao->db,
        $parent->first_step( $dao->db ),
        { started => 1 }
    );
    is $parent_run->data->{started}, 1, 'parent run data is updated';

    my $child_run =
      $child->new_run( $dao->db, { continuation_id => $parent_run->id } );

    $child_run->process( $dao->db, $child_run->next_step( $dao->db ), {}, );

    $child_run->process(
        $dao->db,
        $child_run->next_step( $dao->db ),
        {
            child_data => 1,
        }
    );

    is $child_run->completed( $dao->db ), 1, 'child run is completed';

    ($parent_run) = $dao->find( WorkflowRun => { id => $parent_run->id } );
    is $parent_run->data->{started}, 1, 'parent run data is still there';
    is $parent_run->data->{child_data}, 1,
      'parent run data is updated from child_run';
    $parent_run->process( $dao->db, $parent_run->next_step( $dao->db ) );

}
