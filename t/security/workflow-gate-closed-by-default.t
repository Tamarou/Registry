#!/usr/bin/env perl
# ABOUTME: The workflow gate reads who may run a workflow from the current tenant's own row and
# ABOUTME: refuses (403) a slug with no roles and no public mark, at every entry, creating no run.
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
use Registry::DAO::Workflow;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
$ENV{DB_URL} = $test_db->uri;

# Workflows into registry first: provision copies them into each tenant.
import_all_workflows($dao);

for my $slug (qw( gate_here gate_there )) {
    Registry::DAO::Tenant->provision( $db, { name => "Gate \u$slug", slug => $slug, users => [] } );
}
my $here      = Registry::DAO::Tenant->find( $db, { slug => 'gate_here' } );
my $HOST      = { Host => 'gate_here.localhost' };
my $here_dao  = $dao->connect_schema('gate_here');
my $there_dao = $dao->connect_schema('gate_there');

# A workflow in this tenant's schema with neither roles nor the public mark.
sub workflow_yaml ( $slug, $head = '' ) {
    return "name: $slug\nslug: $slug\ndescription: fixture\n$head"
      . "steps:\n  - slug: first\n    description: x\n  - slug: second\n    description: y\n";
}
Registry::DAO::Workflow->from_yaml( $here_dao, workflow_yaml('unguarded-flow') );

sub member ( $username, $role ) {
    my $user = Registry::DAO::User->create( $db, {
        username => $username, name => "\u$username", user_type => 'staff',
        email    => "$username\@workflow-gate.test",
    } );
    $here->add_user( $db, $user, 0, $role );
    $db->query( 'SELECT copy_user(dest_schema => ?, user_id => ?)', 'gate_here', $user->id );
    return $user;
}

sub app_as ($user = undef) {
    my $t = Test::Registry::Mojo->new('Registry');
    $t->ua->max_redirects(0);
    authenticate_as( $t, $user ) if $user;
    return $t;
}

my $admin  = member( 'gate_admin',  'admin' );
my $parent = member( 'gate_parent', 'parent' );

subtest 'a workflow with no role entry and no public mark is refused for an anonymous visitor' => sub {
    my $t = app_as();
    $t->get_ok( '/unguarded-flow' => $HOST )->status_is(403);
    $t->post_ok( '/unguarded-flow' => $HOST => form => {} )->status_is(403);
};

subtest 'a workflow with no role entry and no public mark is refused for a parent' => sub {
    my $t = app_as($parent);
    $t->get_ok( '/unguarded-flow' => $HOST )->status_is(403);
    $t->post_ok( '/unguarded-flow' => $HOST => form => {} )->status_is(403);
};

done_testing;
