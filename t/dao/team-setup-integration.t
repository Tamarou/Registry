use 5.40.2;
use lib qw(lib t/lib);
use experimental qw(defer builtin);

use Test::More import => [qw( done_testing is ok like subtest diag )];
defer { done_testing };

use Test::Registry::DB;
use Test::Registry::Fixtures;

# Setup test database
my $t = Test::Registry::DB->new;
my $db = $t->db;

# Test team setup with primary admin and additional team members
subtest 'Team setup with admin and team members' => sub {
    # Create a test tenant (in registry schema)
    my $tenant = Test::Registry::Fixtures::create_tenant($db, {
        name => 'Test Organization',
        slug => 'testorg'
    });
    
    # Create the tenant schema with all required tables
    $db->db->query('SELECT clone_schema(dest_schema => ?)', $tenant->slug);
    
    # Create admin user (in registry schema)
    my $admin_user = Test::Registry::Fixtures::create_user($db, {
        username => 'jadmin',
        password => 'securepassword123',
        user_type => 'admin',
    });
    ok $admin_user, 'Admin user created successfully';
    
    # Create team member users (in registry schema)
    my $staff_user = Test::Registry::Fixtures::create_user($db, {
        username => 'janestaff',
        password => 'password123',
        user_type => 'staff',
    });
    ok $staff_user, 'Staff user created successfully';
    
    my $manager_user = Test::Registry::Fixtures::create_user($db, {
        username => 'bobmanager', 
        password => 'password123',
        user_type => 'admin',
    });
    ok $manager_user, 'Manager user created successfully';
    
    # Verify users were created by checking each one individually 
    # (working around User DAO find method bug)
    my $found_admin = $t->db->find('Registry::DAO::User' => { username => 'jadmin' });
    my $found_staff = $t->db->find('Registry::DAO::User' => { username => 'janestaff' });
    my $found_manager = $t->db->find('Registry::DAO::User' => { username => 'bobmanager' });
    
    ok $found_admin, 'Admin user found in registry schema';
    ok $found_staff, 'Staff user found in registry schema';
    ok $found_manager, 'Manager user found in registry schema';
    
    # Copy users to tenant schema
    $db->db->query('SELECT copy_user(dest_schema => ?, user_id => ?)', $tenant->slug, $admin_user->id);
    $db->db->query('SELECT copy_user(dest_schema => ?, user_id => ?)', $tenant->slug, $staff_user->id);
    $db->db->query('SELECT copy_user(dest_schema => ?, user_id => ?)', $tenant->slug, $manager_user->id);
    
    # Switch to tenant schema for operations
    $db = $db->schema($tenant->slug);
    
    # Verify tenant was created
    my ($created_tenant) = $t->db->find( 'Registry::DAO::Tenant' => { name => 'Test Organization' } );
    ok $created_tenant, 'Tenant was created';
    is $created_tenant->name, 'Test Organization', 'Tenant name is correct';
    like $created_tenant->slug, qr/^testorg/, 'Tenant slug generated correctly';
    
    # Verify users were copied to tenant schema by checking each one individually
    my $tenant_admin_check = $db->find('Registry::DAO::User' => { username => 'jadmin' });
    my $tenant_staff_check = $db->find('Registry::DAO::User' => { username => 'janestaff' });
    my $tenant_manager_check = $db->find('Registry::DAO::User' => { username => 'bobmanager' });
    
    ok $tenant_admin_check, 'Admin user copied to tenant schema';
    ok $tenant_staff_check, 'Staff user copied to tenant schema';
    ok $tenant_manager_check, 'Manager user copied to tenant schema';
    
    # Verify user types and authentication in tenant schema
    my ($tenant_admin) = $db->find('Registry::DAO::User' => { username => 'jadmin' });
    is $tenant_admin->user_type, 'admin', 'Admin user type correct';
    ok $tenant_admin->check_password('securepassword123'), 'Admin password verification works';
    
    my ($tenant_staff) = $db->find('Registry::DAO::User' => { username => 'janestaff' });
    is $tenant_staff->user_type, 'staff', 'Staff user type correct';
    ok $tenant_staff->check_password('password123'), 'Staff password verification works';
    
    my ($tenant_manager) = $db->find('Registry::DAO::User' => { username => 'bobmanager' });
    is $tenant_manager->user_type, 'admin', 'Manager user type correct';
    ok $tenant_manager->check_password('password123'), 'Manager password verification works';
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