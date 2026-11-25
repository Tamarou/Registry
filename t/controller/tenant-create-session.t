use 5.42.0;
use lib          qw(lib t/lib);
use experimental qw(defer declared_refs);

# Signup calls no Stripe API; unset ambient keys all the same, so nothing
# here can reach the live one.
BEGIN { delete @ENV{qw(STRIPE_SECRET_KEY STRIPE_PUBLISHABLE_KEY)} }

use Test::Mojo;
use Test::More import => [qw( done_testing is note ok )];
defer { done_testing };

use Registry::DAO;
use Registry::DAO::User;
use Test::Registry::DB;
use Test::Registry::Helpers qw(authenticate_as import_all_workflows process_workflow);
use Data::Dumper;

my $test_db = Test::Registry::DB->new();
my $dao = $test_db->db;
import_all_workflows($dao);

$ENV{DB_URL} = $dao->url;

my $t = Test::Mojo->new('Registry');

# Add cleanup END block to prevent database connection issues
END {
    # Force disconnection of database handles before destruction
    eval { $dao->db->disconnect if $dao && $dao->can('db') && $dao->db->can('disconnect') };
}
{
    process_workflow(
        $t,
        '/tenant-signup' => {
            name             => 'Test Tenant',
            billing_email    => 'alice@example.com',
            billing_address  => '123 Main St',
            billing_city     => 'Anytown',
            billing_state    => 'CA',
            billing_zip      => '12345',
            billing_country  => 'US',
            admin_name       => 'Alice',
            admin_email      => 'alice@example.com',
            admin_username   => 'Alice',
            terms_accepted   => '1',
            offer_version    => platform_solo_offer_version_id($dao),
        }
    );
    
    ok my ($tenant) = $dao->find( Tenant => { name => 'Test Tenant' } ),
      'got tenant';
    ok my $tenant_dao = $tenant->dao( $dao->db ), 'connected to tenant schema';

    # Debug: Check what users exist
    my @users = $dao->find( User => {} );
    note "Found users: " . join(', ', map { $_->username // 'no-username' } @users);
    
    ok $dao->find( User => { username => 'Alice' } ),
      'found Alice in main schema';
    ok $tenant_dao->find( User => { username => 'Alice' } ),
      'found Alice in tenant schema';
    is $tenant->primary_user( $dao->db )->username, 'Alice',
      'Primary user is correct';

    # check that the user-creation workflow exists in the tenant
    ok $tenant_dao->find( Workflow => { slug => 'user-creation' } ),
      'user-creation workflow exists in tenant schema';

    # Establish a session for Alice so X-As-Tenant header is respected
    # (the tenant helper only reads X-As-Tenant for authenticated users)
    my $alice = $dao->find( User => { username => 'Alice' } );
    authenticate_as($t, $alice);

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
