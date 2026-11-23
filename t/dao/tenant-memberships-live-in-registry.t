#!/usr/bin/env perl
# ABOUTME: A tenant's memberships are registry.tenant_users rows, whichever schema the handle searches.
# ABOUTME: A tenant-scoped handle once wrote them into the tenant schema's cloned tenant_users instead.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;

use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::User;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

# clone_schema gives every tenant schema its own copy of tenant_users, and a
# tenant-scoped handle searches only that schema and public -- not registry.
my $tenant = Test::Registry::Fixtures::create_tenant( $dao->db, { name => 'Member Studio', slug => 'member_studio' } );
$dao->db->query( 'SELECT clone_schema(?)', 'member_studio' );
my $tenant_db = Registry::DAO->new( url => $test_db->uri, schema => 'member_studio' )->db;

sub registry_membership ($user) {
    return $dao->db->query(
        'SELECT role, is_primary FROM registry.tenant_users WHERE tenant_id = ? AND user_id = ?',
        $tenant->id, $user->id )->hash;
}

subtest 'add_user on a tenant-scoped handle records the membership in registry' => sub {
    my $user = Registry::DAO::User->create( $dao->db, { username => 'member_staff', user_type => 'admin' } );

    $tenant->add_user( $tenant_db, $user, 0, 'staff' );

    my $row = registry_membership($user);
    ok $row, 'the membership is a registry.tenant_users row';
    is $row->{role}, 'staff', 'with the role it was given';
};

subtest 'set_primary_user on a tenant-scoped handle records the membership in registry' => sub {
    my $user = Registry::DAO::User->create( $dao->db, { username => 'member_founder', user_type => 'admin' } );

    $tenant->set_primary_user( $tenant_db, $user );

    my $row = registry_membership($user);
    ok $row, 'the membership is a registry.tenant_users row';
    ok $row->{is_primary}, 'marked primary';
    is $row->{role}, 'admin', "with the founder's role";
};

subtest 'a tenant-scoped handle reads the memberships registry holds' => sub {
    my $founder = Registry::DAO::User->find( $dao->db, { username => 'member_founder' } );

    is $tenant->primary_user($tenant_db)->id, $founder->id, 'primary_user finds the founder';
    is scalar( $tenant->users($tenant_db) ), 2, 'users finds both members';
};

done_testing;
