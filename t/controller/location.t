use 5.40.2;
use lib          qw(lib t/lib);
use experimental qw(defer builtin declared_refs);

use Test::Mojo;
use Test::More import => [qw(done_testing is note ok)];
defer { done_testing };

use Mojo::Home;
use Registry::DAO;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw(process_workflow);
use YAML::XS                qw(Load);

# Set up test database using fixtures pattern
my $t_db = Test::Registry::DB->new;
my $dao = $t_db->db;
$ENV{DB_URL} = $t_db->uri;

# Load location-management workflow needed for this test  
my $workflow_dir = Mojo::Home->new->child('workflows');
my $workflow_file = $workflow_dir->child('location-management.yaml');
if (-f $workflow_file) {
    my $yaml = $workflow_file->slurp;
    unless (Load($yaml)->{draft}) {
        Workflow->from_yaml( $dao, $yaml );
    }
}

my $t = Test::Mojo->new('Registry');

# Create a tenant using fixtures
my $tenant = Test::Registry::Fixtures::create_tenant($dao, {
    name => 'Location Test Tenant',
    slug => 'location_test_tenant',
});

ok $tenant, 'got tenant';

# Clone schema to set up tenant database structure  
$dao->db->query('SELECT clone_schema(dest_schema => ?)', $tenant->slug);

# Create a new DAO instance for the tenant schema instead of switching
my $tenant_dao = Registry::DAO->new(url => $ENV{DB_URL}, schema => $tenant->slug);

# Verify we can create a location in the tenant schema
my $location = Test::Registry::Fixtures::create_location($tenant_dao, {
    name => 'Test Location',
    slug => 'test_location',
    address_info => {
        street_address => '123 Test St',
        city => 'Portland', 
        state => 'OR',
        postal_code => '97201'
    }
});

ok $location, 'created test location';
is $location->name, 'Test Location', 'location has correct name';
is $location->slug, 'test_location', 'location has correct slug';


# Test viewing the location with tenant context
$t->get_ok( "/locations/" . $location->slug, { 'X-As-Tenant' => $tenant->slug } )
  ->status_is(200)
  ->content_like(qr/Test Location/)
  ->content_like(qr/123 Test St/);

# Test location isolation - check that location doesn't exist in main schema
is $dao->find( Location => { name => 'Test Location' } ), undef,
  'location not in main schema';
