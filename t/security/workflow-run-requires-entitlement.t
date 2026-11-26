#!/usr/bin/env perl
# ABOUTME: The workflow gate requires the request's tenant to hold an in-effect run entitlement from registry
# ABOUTME: for the slug before it asks the visitor's role, on the direct route and the callcc leg, failing closed.
use 5.42.0;
use warnings;
use utf8;
use experimental 'signatures';

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Helpers qw(authenticate_as import_all_workflows);
use Registry::DAO::Tenant;
use Registry::DAO::User;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
$ENV{DB_URL} = $test_db->uri;

import_all_workflows($dao);

# Provisioned without accepting Solo: until 01a20415-6a27 it still receives a
# copy of every platform workflow, but holds no run right to any of them.
my $bare     = Registry::DAO::Tenant->provision( $db, { name => 'Bare Studio', slug => 'bare_studio', users => [] } );
my $BARE     = { Host => 'bare_studio.localhost' };
my $bare_dao = $dao->connect_schema('bare_studio');

sub member ( $tenant, $username, $role ) {
    my $user = Registry::DAO::User->create( $db, {
        username => $username, name => "\u$username", user_type => 'staff',
        email    => "$username\@run-entitlement.test",
    } );
    $tenant->add_user( $db, $user, 0, $role );
    $db->query( 'SELECT copy_user(dest_schema => ?, user_id => ?)', $tenant->slug, $user->id );
    return $user;
}

sub app_as ($user = undef) {
    my $t = Test::Registry::Mojo->new('Registry');
    $t->ua->max_redirects(0);
    authenticate_as( $t, $user ) if $user;
    return $t;
}

sub runs_of ( $tdao, $slug ) {
    $tdao->db->query( q{
        SELECT count(*) FROM workflow_runs r JOIN workflows w ON w.id = r.workflow_id WHERE w.slug = ?
    }, $slug )->array->[0];
}

my $bare_admin = member( $bare, 'bare_admin', 'admin' );

subtest 'a copied workflow without a run entitlement is refused to an authorised admin' => sub {
    ok $bare_dao->find( 'Registry::DAO::Workflow', { slug => 'program-creation' } ), 'the tenant holds a copy';
    my $t = app_as($bare_admin);
    $t->get_ok( '/program-creation' => $BARE )->status_is(403);
    $t->post_ok( '/program-creation' => $BARE => form => {} )->status_is(403);
    is runs_of( $bare_dao, 'program-creation' ), 0, 'no run was created';
};

done_testing;
