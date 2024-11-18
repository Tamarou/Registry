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
            name     => 'Test Customer',
            username => 'Alice',
            password => 'password',
        }
    );

    ok my ($customer) = $dao->find( Customer => { name => 'Test Customer' } ),
      'got customer';
    is $customer->primary_user( $dao->db )->username, 'Alice',
      'Primary user is correct';

    ok my $customer_dao = $dao->connect_schema( $customer->slug ),
      'connected to customer schema';
    ok $customer_dao->find( User => { username => 'Alice' } ),
      'found Alice in the customer schema';

    $t->get_ok( '/user-creation', { 'X-As-Customer' => $customer->slug } )
      ->status_is(200);
    {
        process_workflow(
            $t,
            '/user-creation' => {
                username => 'Bob',
                password => 'password',
            },
            { 'X-As-Customer' => $customer->slug }
        );
        ok $customer_dao->find( User => { username => 'Bob' } ),
          'found bob in the customer schema';
        is $dao->find( User => { username => 'Bob' } ), undef,
          'Bob not in the main schema';
    }

    # customes can create sessions
    {
        use Time::Piece qw( localtime );
        my $time = localtime;
        process_workflow(
            $t,
            '/session-creation' => {
                name       => 'Test Session',
                time       => $time->datetime,
                teacher_id => $customer->primary_user( $dao->db )->id,
            },
            { 'X-As-Customer' => $customer->slug }
        );
    }
}
