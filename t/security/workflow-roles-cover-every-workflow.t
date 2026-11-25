#!/usr/bin/env perl
# ABOUTME: Every imported workflow's row carries roles or the public mark, read from the data the gate reads.
# ABOUTME: A workflow added with neither fails here, by file and slug, instead of being refused to everyone.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Helpers qw(import_all_workflows);
use Registry::DAO::Tenant;
use Mojo::Home;
use Mojo::File;

# The gate (require_workflow_role in Registry.pm) refuses a workflow whose row
# has neither roles nor the public mark, so a workflow shipped with neither is
# shut to everyone. This test catches that before a visitor does, reading the
# same rows the gate reads.
my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

use Test::Registry::WorkflowRoleCoverage;
use File::Temp;

my $entry = sub ($slug) { $db->select( 'registry.workflows', [qw(roles public)], { slug => $slug } )->hash };

subtest 'every shipped workflow has a role entry or the public mark' => sub {
    import_all_workflows($dao);
    my $dir = Mojo::Home->new->child('workflows');
    ok scalar $dir->list_tree->grep(qr/\.ya?ml\z/)->each, 'there are workflow files to check';
    is_deeply [ Test::Registry::WorkflowRoleCoverage::problems( $dir, $entry ) ], [],
      'and none of them is uncovered, contradictory, unimported or unreadable';
};

subtest "every workflow a tenant is provisioned with keeps its entry" => sub {
    Registry::DAO::Tenant->provision( $db, { name => 'Coverage', slug => 'coverage', users => [] } );
    ok $db->query('SELECT count(*) FROM coverage.workflows')->array->[0], 'the tenant has workflows';
    is_deeply $db->query( q{
        SELECT slug FROM coverage.workflows
         WHERE NOT public AND coalesce(cardinality(roles), 0) = 0 ORDER BY slug
    } )->arrays->map( sub { $_->[0] } )->to_array, [], 'none of them has neither roles nor the mark';
};

# The checks below import workflows written for the purpose, each slug once
# (from_yaml leaves an existing row alone), so each rule is exercised on its own.
sub problems_for (%files) {
    my $dir = File::Temp->newdir;
    my @paths;
    for my $name ( keys %files ) {
        my $file = Mojo::File->new("$dir/$name");
        $file->dirname->make_path;
        $file->spew( $files{$name} );
        push @paths, $file;
    }
    eval { $dao->import_workflows( \@paths ) };    # an unparseable file dies here; the check names it

    return [ Test::Registry::WorkflowRoleCoverage::problems( "$dir", $entry ) ];
}

sub workflow_yaml ( $slug, %extra ) {
    my $yaml = "name: $slug\nslug: $slug\ndescription: fixture\n";
    $yaml .= "$_: $extra{$_}\n" for sort keys %extra;
    return $yaml . "steps:\n  - slug: only\n    description: x\n";
}

# The importers (Registry->import_workflows, `registry workflow import`) walk
# workflows/ with list_tree, so a file in a subdirectory is imported too.
subtest 'a workflow in a subdirectory is checked like any other' => sub {
    my $problems = problems_for( 'sub/nested.yml' => workflow_yaml('nested-flow') );
    is scalar @$problems, 1, 'the nested file is checked';
    like $problems->[0], qr{sub/nested\.yml}, 'reported by its path under the directory';
    like $problems->[0], qr/nested-flow/, 'and by its slug';
};

subtest 'a workflow with no role entry and no public mark is reported by file and slug' => sub {
    my $problems = problems_for( 'forgotten.yml' => workflow_yaml('forgotten-flow') );
    is scalar @$problems, 1, 'one problem';
    like $problems->[0], qr/forgotten\.yml/,    'naming the file';
    like $problems->[0], qr/forgotten-flow/,    'and the slug';
    like $problems->[0], qr/no roles and no public mark/, 'and what is wrong';
};

subtest 'a roles workflow is covered' => sub {
    is_deeply problems_for( 'guarded.yml' => workflow_yaml( 'guarded-flow', roles => '[admin]' ) ), [],
      'roles: [admin] is an entry';
};

subtest 'only a yaml boolean true counts as the public mark' => sub {
    is_deeply problems_for( 'a.yml' => workflow_yaml( 'a-flow', public => 'true' ) ), [],
      'public: true is the mark';
    my $n = 0;
    for my $not_the_mark ( 'false', '"true"', '1', 'yes' ) {
        my $problems = problems_for( 'b.yml' => workflow_yaml( 'b-flow-' . ++$n, public => $not_the_mark ) );
        is scalar @$problems, 1, "public: $not_the_mark is not the mark";
    }
};

subtest 'a draft workflow is skipped and a non-draft one is checked' => sub {
    is_deeply problems_for( 'draft.yml' => workflow_yaml( 'draft-flow', draft => 'true' ) ), [],
      'draft: true is skipped, as the importer skips it';
    is scalar problems_for( 'live.yml' => workflow_yaml( 'live-flow', draft => 'false' ) )->@*, 1,
      'draft: false is checked';
};

subtest 'the yaml slug is checked, not the file name' => sub {
    my $problems = problems_for( 'guarded-flow.yml' => workflow_yaml('uncovered-flow') );
    is scalar @$problems, 1, 'a file named after a guarded slug is still checked by its own slug';
    like $problems->[0], qr/uncovered-flow/, 'and the slug reported is the YAML one';
};

subtest 'an unparseable workflow file fails the check by name' => sub {
    my $problems = problems_for( 'broken.yml' => "name: [unterminated\n" );
    is scalar @$problems, 1, 'one problem, not a skip';
    like $problems->[0], qr/broken\.yml/, 'naming the file';
    like $problems->[0], qr/does not parse/, 'and saying why';
};

subtest 'a workflow the importer refused has no row and fails the check' => sub {
    my $problems = problems_for( 'both.yml' => workflow_yaml( 'both-flow', public => 'true', roles => '[admin]' ) );
    is scalar @$problems, 1, 'one problem';
    like $problems->[0], qr/both\.yml.*both-flow.*no stored workflow row/, 'naming the file and slug';
};

# Import refuses both, so only a hand-written row can hold them together.
subtest 'a row with both roles and the public mark fails as contradictory' => sub {
    $db->insert( 'registry.workflows',
        { name => 'x', slug => 'contra-flow', description => 'x', roles => ['admin'], public => 1 } );
    my $problems = problems_for( 'contra.yml' => workflow_yaml('contra-flow') );
    is scalar @$problems, 1, 'one problem';
    like $problems->[0], qr/contra\.yml.*contra-flow/, 'naming the file and slug';
    like $problems->[0], qr/contradict/, 'as contradictory';
};

done_testing;
