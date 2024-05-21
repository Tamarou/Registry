use 5.38.0;
use lib          qw(lib t/lib);
use experimental qw(defer builtin);
use builtin      qw(blessed);

use Test::More import => [qw( done_testing is ok )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB qw(DAO Workflow WorkflowRun WorkflowStep);
my $dao = Registry::DAO->new( url => Test::Registry::DB->new_test_db() );

{
    # create a new customer
    my $workflow = $dao->find( Workflow => { slug => 'customer-signup' } );
    is $workflow->name, 'Customer Onboarding', 'Workflow name is correct';
    is $workflow->first_step( $dao->db )->slug, 'landing',
      'First step name is correct';
    is $workflow->last_step( $dao->db )->slug, 'complete',
      'Last step name is correct';
    is $workflow->last_step( $dao->db ) isa WorkflowStep,
      1, 'Next step isa WorkflowStep';
    is blessed $workflow->last_step( $dao->db ),
      'Registry::DAO::RegisterCustomer',
      'Next step is a WorkflowStep';

    my $run = $workflow->new_run( $dao->db );
    is $run->next_step( $dao->db )->slug, 'landing', 'Next step is correct';
    $run->process( $dao->db, $run->next_step( $dao->db ), {} );
    is $run->next_step( $dao->db )->slug, 'profile', 'Next step is correct';
    $run->process(
        $dao->db,
        $run->next_step( $dao->db ),
        { slug => 'big_cups', name => 'Big Cups Ltd.' }
    );
    is $run->next_step( $dao->db )->slug, 'users', 'Next step is correct';
    $run->process(
        $dao->db,
        $run->next_step( $dao->db ),
        [
            { username => 'Alice', password => 'abc123' },
            { username => 'Bob',   password => 'password' }
        ]
    );
    is $run->next_step( $dao->db )->slug, 'complete', 'Next step is correct';
    $run->process( $dao->db, $run->next_step( $dao->db ), {} );
    is $run->next_step( $dao->db ), undef, 'Next step is correct';

    my $customer =
      $dao->find( Customer => { name => $run->data->{profile}{name} } );
    is $customer->name, 'Big Cups Ltd.', 'Customer exists';
    is $customer->primary_user( $dao->db )->username, 'Alice',
      'Primary user is correct';

    my @users = $customer->users( $dao->db );
    is $users[0]->username, 'Alice', 'First user is correct';
    is $users[1]->username, 'Bob',   'Second user is correct';

    # check that the customer is in their own schema
    my $dao2 =
      Registry::DAO->new( url => $dao->url, schema => $customer->slug );

    is $dao2->find( User => { username => 'Alice' } )->username, 'Alice',
      'User exists';
    is $dao2->find( User => { username => 'Bob' } )->username, 'Bob',
      'User exists';

    is $dao2->find( Customer => {} ), undef, 'No customers exists';
}

