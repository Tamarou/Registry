# ABOUTME: Tests for Registry::DAO::Tenant->provision class method.
# ABOUTME: Verifies tenant creation copies all workflows (except tenant-signup) and users.
use 5.42.0;
use lib qw(lib t/lib);
use experimental qw(defer keyword_any);
use Test::More import => [qw(done_testing is ok)];
defer { done_testing };

use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Test::Registry::DB;
use Test::Registry::Helpers qw(import_all_workflows);

my $t_db = Test::Registry::DB->new;
my $dao  = $t_db->db;            # keep $dao alive
$ENV{DB_URL} = $t_db->uri;
my $db = $dao->db;

import_all_workflows($dao);

my $admin = Registry::DAO::User->create($db, {
    username => 'prov_admin', user_type => 'admin',
    email => 'prov_admin@test.com', name => 'Prov Admin',
});

my $tenant = Registry::DAO::Tenant->provision($db, {
    name  => 'Provision Test',
    slug  => 'provision1',
    users => [ $admin ],
});
ok $tenant, 'provision returned a tenant';
is $tenant->slug, 'provision1', 'tenant slug as requested';

my $tenant_dao = Registry::DAO->new(url => $ENV{DB_URL}, schema => $tenant->slug);
my @slugs = map { $_->{slug} } $tenant_dao->db->select('workflows', ['slug'])->hashes->each;
for my $need (qw(program-creation program-location-assignment tenant-storefront session-creation event-creation user-creation)) {
    ok( (any { $_ eq $need } @slugs), "tenant has '$need' workflow" );
}
ok( !(any { $_ eq 'tenant-signup' } @slugs), 'tenant does NOT have tenant-signup' );

my $copied = $tenant_dao->find(User => { username => 'prov_admin' });
ok $copied, 'admin user copied into tenant schema';
