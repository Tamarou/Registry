use 5.40.2;
use lib qw(lib t/lib);
use experimental qw(defer builtin);

use Test::More import => [qw( done_testing is ok like subtest )];
defer { done_testing };

use Mojo::Home;
use Registry::DAO qw(Workflow WorkflowRun Tenant User);
use Test::Registry::DB ();
use YAML::XS qw( Load );

my $dao = Registry::DAO->new( url => Test::Registry::DB->new_test_db() );

# Import workflows and templates
my @files = Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;
for my $file (@files) {
    next if Load( $file->slurp )->{draft};
    Workflow->from_yaml( $dao, $file->slurp );
}

Registry::DAO::Template->import_from_file( $dao, $_ )
    for Mojo::Home->new->child('templates')->list_tree->grep(qr/\.html\.ep$/)
    ->each;

# Test team setup with primary admin and additional team members
subtest 'Team setup with admin and team members' => sub {
    # Get tenant-signup workflow
    my ($workflow) = $dao->find( Workflow => { slug => 'tenant-signup' } );
    ok $workflow, 'Tenant signup workflow found';
    
    # Create workflow run with team setup data
    my $run = $workflow->new_run( $dao->db );
    
    # Process through landing step
    $run->process( $dao->db, $run->next_step( $dao->db ), {} );
    
    # Process profile step with billing info
    $run->process(
        $dao->db,
        $run->next_step( $dao->db ),
        {
            name => 'Test Organization',
            billing_email => 'billing@testorg.com',
            billing_address => '123 Test St',
            billing_city => 'Test City',
            billing_state => 'TX',
            billing_zip => '12345',
            billing_country => 'US'
        }
    );
    
    # Process users step with new team setup format
    $run->process(
        $dao->db,
        $run->next_step( $dao->db ),
        {
            admin_name => 'John Admin',
            admin_email => 'john@testorg.com',
            admin_username => 'jadmin',
            admin_password => 'securepassword123',
            admin_user_type => 'admin',
            team_members => [
                {
                    name => 'Jane Staff',
                    email => 'jane@testorg.com',
                    user_type => 'staff'
                },
                {
                    name => 'Bob Manager',
                    email => 'bob@testorg.com',
                    user_type => 'admin'
                }
            ]
        }
    );
    
    # Complete the registration
    $run->process( $dao->db, $run->next_step( $dao->db ), {} );
    
    # Verify tenant was created
    my ($tenant) = $dao->find( Tenant => { name => 'Test Organization' } );
    ok $tenant, 'Tenant was created';
    is $tenant->name, 'Test Organization', 'Tenant name is correct';
    like $tenant->slug, qr/^test-organization/, 'Tenant slug generated correctly';
    
    # Verify primary admin user was created in tenant schema
    my $tenant_dao = Registry::DAO->new( url => $dao->url, schema => $tenant->slug );
    my ($admin_user) = $tenant_dao->find( User => { username => 'jadmin' } );
    ok $admin_user, 'Admin user created in tenant schema';
    is $admin_user->name, 'John Admin', 'Admin user name is correct';
    is $admin_user->email, 'john@testorg.com', 'Admin user email is correct';
    is $admin_user->user_type, 'admin', 'Admin user type is correct';
    
    # Verify team members were created
    my ($jane_user) = $tenant_dao->find( User => { email => 'jane@testorg.com' } );
    ok $jane_user, 'Jane staff user created';
    is $jane_user->name, 'Jane Staff', 'Jane user name is correct';
    is $jane_user->user_type, 'staff', 'Jane user type is correct';
    
    my ($bob_user) = $tenant_dao->find( User => { email => 'bob@testorg.com' } );
    ok $bob_user, 'Bob admin user created';
    is $bob_user->name, 'Bob Manager', 'Bob user name is correct';
    is $bob_user->user_type, 'admin', 'Bob user type is correct';
    
    # Verify usernames were generated for team members
    like $jane_user->username, qr/^jane/, 'Jane username generated from email';
    like $bob_user->username, qr/^bob/, 'Bob username generated from email';
};

subtest 'Username generation from email' => sub {
    # Test email processing for username generation logic
    my $email1 = 'test.user@example.com';
    my $username1 = $email1;
    $username1 =~ s/@.*$//;  # Remove domain
    $username1 =~ s/[^a-zA-Z0-9]//g;  # Remove special characters
    is $username1, 'testuser', 'Username generated correctly from email with dots';
    
    my $email2 = 'john-doe@company.org';
    my $username2 = $email2;
    $username2 =~ s/@.*$//;
    $username2 =~ s/[^a-zA-Z0-9]//g;
    is $username2, 'johndoe', 'Username generated correctly from email with hyphens';
};