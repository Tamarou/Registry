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
use Data::Dumper;

my $test_db = Test::Registry::DB->new();
my $dao = $test_db->db;
my $workflow_dir = Mojo::Home->new->child('workflows');
my @files        = $workflow_dir->list_tree->grep(qr/\.ya?ml$/)->each;
for my $file (@files) {
    next if Load( $file->slurp )->{draft};
    Workflow->from_yaml( $dao, $file->slurp );
}

$ENV{DB_URL} = $dao->url;

# Set up a pricing relationship for the test to use
# Create a test user for the pricing relationship (required as consumer)
my $test_user = Registry::DAO::User->find_or_create($dao->db, {
    username => 'test_relationship_user',
    passhash => '$2b$12$DummyHashForTesting'
});

# Get the Registry Standard pricing plan and create pricing relationship for the test
my $standard_plan = Registry::DAO::PricingPlan->find($dao->db, { plan_name => 'Registry Standard - $200/month' });
if ($standard_plan) {
    # Create pricing relationship between platform tenant and standard plan
    Registry::DAO::PricingRelationship->create($dao->db, {
        provider_id => '00000000-0000-0000-0000-000000000000',  # Platform tenant UUID
        consumer_id => $test_user->id,
        pricing_plan_id => $standard_plan->id,
        status => 'active'
    });
}

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
            admin_password   => 'password',
            terms_accepted   => '1',
            # Mock payment data to satisfy workflow
            setup_intent_id  => 'seti_test_123',
            payment_method_id => 'pm_test_123',
            collect_payment_method => '1',
            # Pricing plan selection - using Registry Standard plan (ID will be looked up)
            selected_plan_id => $standard_plan ? $standard_plan->id : 'cb4e92cf-193a-4832-b785-608c4b02dac8',
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
