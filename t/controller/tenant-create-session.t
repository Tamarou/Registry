use 5.40.0;
use lib          qw(lib t/lib);
use experimental qw(defer builtin declared_refs);

use Test::Mojo;
use Test::More import => [qw( done_testing is note ok )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;
use Test::Registry::Helpers qw(process_workflow);

my $dao = Registry::DAO->new( url => Test::Registry::DB->new_test_db() );

$ENV{DB_URL} = $dao->url;

my $t = Test::Mojo->new('Registry');
{
    process_workflow(
        $t,
        '/tenant-signup' => {
            name     => 'Test Tenant',
            username => 'Alice',
            password => 'password',
        }
    );

    ok my ($tenant) = $dao->find( Tenant => { name => 'Test Tenant' } ),
      'got tenant';
    is $tenant->primary_user( $dao->db )->username, 'Alice',
      'Primary user is correct';

    ok my $tenant_dao = $dao->connect_schema( $tenant->slug ),
      'connected to tenant schema';
    ok $tenant_dao->find( User => { username => 'Alice' } ),
      'found Alice in the tenant schema';

    $t->get_ok( '/user-creation', { 'X-As-Tenant' => $tenant->slug } )
      ->status_is(200);
    {
        process_workflow(
            $t,
            '/user-creation' => {
                username => 'Bob',
                password => 'password',
            },
            { 'X-As-Tenant' => $tenant->slug }
        );
        ok $tenant_dao->find( User => { username => 'Bob' } ),
          'found bob in the tenant schema';
        is $dao->find( User => { username => 'Bob' } ), undef,
          'Bob not in the main schema';
    }

    # tenants can create sessions
    {
        use Time::Piece qw( localtime );
        my $time = localtime;
        process_workflow(
            $t,
            '/session-creation' => {
                name       => 'Test Session',
                time       => $time->datetime,
                teacher_id => $tenant->primary_user( $dao->db )->id,
            },
            { 'X-As-Tenant' => $tenant->slug }
        );
    }
}
