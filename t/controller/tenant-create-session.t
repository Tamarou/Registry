use 5.40.2;
use lib          qw(lib t/lib);
use experimental qw(defer builtin declared_refs);

use Test::Mojo;
use Test::More import => [qw( done_testing is note ok )];
defer { done_testing };

use Mojo::Home;
use Registry::DAO;
use Test::Registry::DB;
use Test::Registry::Helpers qw(process_workflow);
use YAML::XS                qw( Load );

my $test_db = Test::Registry::DB->new();
my $dao = $test_db->db;
my $workflow_dir = Mojo::Home->new->child('workflows');
my @files        = $workflow_dir->list_tree->grep(qr/\.ya?ml$/)->each;
for my $file (@files) {
    next if Load( $file->slurp )->{draft};
    Workflow->from_yaml( $dao, $file->slurp );
}

$ENV{DB_URL} = $dao->url;

my $t = Test::Mojo->new('Registry');
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
            admin_password   => 'password',
            terms_accepted   => '1',
            # Mock payment data to satisfy workflow
            setup_intent_id  => 'seti_test_123',
            payment_method_id => 'pm_test_123',
            collect_payment_method => '1',
        }
    );
    
    # Debug: Print what's in the request logs
    note "Debug: Check the application logs above for workflow processing details";

    # Debug: Check what tenants exist
    my @tenants = $dao->find( Tenant => {} );
    note "Found tenants: " . join(', ', map { $_->name // 'unnamed' } @tenants);
    
    ok my ($tenant) = $dao->find( Tenant => { name => 'Registry System' } ),
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
