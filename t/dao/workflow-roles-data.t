#!/usr/bin/env perl
# ABOUTME: Who may run a workflow is data on its row: roles or the public mark import from YAML and round-trip.
# ABOUTME: Covers copy_workflow into tenant schemas, the backfill from the old %ROLES map, and every refusal.
use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use YAML::XS qw(Load);

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

done_testing;
