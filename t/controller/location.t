use 5.40.0;
use lib          qw(lib t/lib);
use experimental qw(defer builtin declared_refs);

use Test::Mojo;
use Test::More import => [qw(done_testing is note ok)];
defer { done_testing };

use Mojo::Home;
use Registry::DAO;
use Test::Registry::DB;
use Test::Registry::Helpers qw(process_workflow);
use YAML::XS                qw(Load);

my $dao = Registry::DAO->new( url => Test::Registry::DB->new_test_db() );
my $workflow_dir = Mojo::Home->new->child('workflows');
my @files        = $workflow_dir->list_tree->grep(qr/\.ya?ml$/)->each;
for my $file (@files) {
    next if Load( $file->slurp )->{draft};
    Workflow->from_yaml( $dao, $file->slurp );
}

$ENV{DB_URL} = $dao->url;

my $t = Test::Mojo->new('Registry');
{
    # First create a tenant to test with
    process_workflow(
        $t,
        '/tenant-signup' => {
            name     => 'Location Test Tenant',
            username => 'location_manager',
            password => 'password',
        }
    );

    ok my ($tenant) =
      $dao->find( Tenant => { name => 'Location Test Tenant' } ),
      'got tenant';
    ok my $tenant_dao = $tenant->dao( $dao->db ), 'connected to tenant schema';

    # Test the location management workflow within the tenant context
    $t->get_ok( '/location-management', { 'X-As-Tenant' => $tenant->slug } )
      ->status_is(200);

    process_workflow(
        $t,
        '/location-management' => {
            name                          => 'Test Location',
            'address_info.street_address' => '123 Test St',
            'address_info.city'           => 'Portland',
            'address_info.state'          => 'OR',
            'address_info.postal_code'    => '97201'
        },
        { 'X-As-Tenant' => $tenant->slug }
    );

    # Verify location was created in tenant schema
    ok my ($location) =
      $tenant_dao->find( Location => { name => 'Test Location' } ),
      'found location in tenant schema';
    is $location->address_info->{street_address}, '123 Test St',
      'location has correct street address';
    is $location->address_info->{city}, 'Portland', 'location has correct city';
    is $location->slug, 'test_location',
      'location has correct auto-generated slug';

    # Verify location isolation
    is $dao->find( Location => { name => 'Test Location' } ), undef,
      'location not in main schema';

    # Test viewing the location
    $t->get_ok( "/locations/" . $location->slug,
        { 'X-As-Tenant' => $tenant->slug } )->status_is(200)
      ->content_like(qr/Test Location/)->content_like(qr/123 Test St/);
}
