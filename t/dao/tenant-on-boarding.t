use 5.40.0;
use lib          qw(lib t/lib);
use experimental qw(defer builtin);

use Test::More import => [qw( done_testing is )];
defer { done_testing };

use Mojo::Home;
use Registry::DAO      qw(WorkflowStep);
use Test::Registry::DB ();
use YAML::XS           qw( Load );

my $dao = Registry::DAO->new( url => Test::Registry::DB->new_test_db() );
my @files =
  Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;
for my $file (@files) {
    next if Load( $file->slurp )->{draft};
    Workflow->from_yaml( $dao, $file->slurp );
}

Registry::DAO::Template->import_from_file( $dao, $_ )
  for Mojo::Home->new->child('templates')->list_tree->grep(qr/\.html\.ep$/)
  ->each;

{
    # create a new tenant
    my ($workflow) = $dao->find( Workflow => { slug => 'tenant-signup' } );
    is $workflow->name, 'Tenant Onboarding', 'Workflow name is correct';
    is $workflow->first_step( $dao->db )->slug, 'landing',
      'First step name is correct';
    is $workflow->last_step( $dao->db )->slug, 'complete',
      'Last step name is correct';
    is $workflow->last_step( $dao->db ) isa Registry::DAO::WorkflowStep,
      1, 'Next step isa WorkflowStep';
    is blessed $workflow->last_step( $dao->db ),
      'Registry::DAO::RegisterTenant',
      'Next step is a WorkflowStep';

    my $run = $workflow->new_run( $dao->db );
    is $run->next_step( $dao->db )->slug, 'landing', 'Next step is landing';
    $run->process( $dao->db, $run->next_step( $dao->db ), {} );
    is $run->next_step( $dao->db )->slug, 'profile', 'Next step is profile';
    $run->process(
        $dao->db,
        $run->next_step( $dao->db ),
        { slug => 'big_cups', name => 'Big Cups Ltd.' }
    );
    is $run->next_step( $dao->db )->slug, 'users', 'Next step is users';
    $run->process(
        $dao->db,
        $run->next_step( $dao->db ),
        {
            users => [
                { username => 'Alice', password => 'abc123' },
                { username => 'Bob',   password => 'password' },
            ]
        }
    );
    is $run->next_step( $dao->db )->slug, 'complete', 'Next step is complete';
    $run->process( $dao->db, $run->next_step( $dao->db ), {} );
    is $run->next_step( $dao->db ), undef, 'Next step is correct';

    my ($tenant) =
      $dao->find( Tenant => { name => $run->data->{name} } );
    is $tenant->name, 'Big Cups Ltd.', 'Tenant exists';
    is $tenant->primary_user( $dao->db )->username, 'Alice',
      'Primary user is correct';

    # users associated with the tenant
    my @users = $tenant->users( $dao->db );
    is $users[0]->username, 'Alice', 'First user is correct';

    # check that the tenant is in their own schema
    my $dao2 = Registry::DAO->new( url => $dao->url, schema => $tenant->slug );

    my ($alice) = $dao2->find( User => { username => 'Alice' } );
    is $alice->username, 'Alice', 'User exists';
    my ($bob) = $dao2->find( User => { username => 'Bob' } );
    is $bob->username, 'Bob', 'User exists';

    is $dao2->find( Tenant => {} ), undef, 'No tenants exists';
}
