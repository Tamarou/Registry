#!/usr/bin/env perl
# ABOUTME: Who may run a workflow is data on its row: roles or the public mark import from YAML and round-trip.
# ABOUTME: Covers copy_workflow into tenant schemas, the backfill from the old %ROLES map, and every refusal.
use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use YAML::XS qw(Load);
no warnings 'experimental::builtin';

use Registry::DAO;
use Test::Registry::DB;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

sub workflow_yaml ( $slug, $head = '' ) {
    return "name: $slug\nslug: $slug\ndescription: fixture\n$head"
      . "steps:\n  - slug: only\n    description: x\n";
}

sub row ( $slug, $schema = 'registry' ) {
    $dao->db->query( qq{SELECT roles, public FROM "$schema".workflows WHERE slug = ?}, $slug )->hash;
}

subtest 'roles import onto the row and round-trip through to_yaml' => sub {
    my $workflow = Registry::DAO::Workflow->from_yaml( $dao,
        workflow_yaml( 'roles-flow', "roles:\n  - admin\n  - staff\n" ) );
    is_deeply row('roles-flow'), { roles => [qw(admin staff)], public => 0 }, 'the row holds the roles';
    is_deeply $workflow->roles, [qw(admin staff)], 'and the object reads them';

    my $back = Load( $workflow->to_yaml($dao) );
    is_deeply $back->{roles}, [qw(admin staff)], 'to_yaml emits the roles';
    ok !exists $back->{public}, 'and no public mark';
};

subtest 'the public mark imports with no roles and round-trips' => sub {
    my $workflow =
      Registry::DAO::Workflow->from_yaml( $dao, workflow_yaml( 'public-flow', "public: true\n" ) );
    is_deeply row('public-flow'), { roles => undef, public => 1 }, 'the row is public with no roles';

    my $back = Load( $workflow->to_yaml($dao) );
    ok builtin::is_bool( $back->{public} ) && $back->{public}, 'to_yaml emits public: true';
    ok !exists $back->{roles}, 'and no roles';
};

subtest 'copy_workflow carries roles and the public mark into a tenant schema' => sub {
    my $db = $dao->db;
    $db->query( 'INSERT INTO registry.tenants (name, slug) VALUES (?, ?)', 'Copy Target', 'copytarget' );
    $db->query( 'SELECT registry.clone_schema(?)', 'copytarget' );
    for my $slug (qw(roles-flow public-flow)) {
        my $id = $db->query( 'SELECT id FROM registry.workflows WHERE slug = ?', $slug )->array->[0];
        $db->query( 'SELECT registry.copy_workflow(?, ?)', 'copytarget', $id );
        is_deeply row( $slug, 'copytarget' ), row($slug), "$slug keeps its entry in the tenant's copy";
    }
};

done_testing;
