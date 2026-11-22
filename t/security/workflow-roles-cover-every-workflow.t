#!/usr/bin/env perl
# ABOUTME: Every imported workflow is either guarded by a workflow_roles entry or deliberately marked public.
# ABOUTME: A workflow added with neither fails here, by file and slug, instead of being silently open to anyone.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;
use Mojo::Home;

# The role gate is open by default: require_workflow_role lets a slug with no
# workflow_roles entry through (Registry.pm, "or return 1"). Until step 6 makes
# who-may-run-what data, the guard is this test: a workflow the importer would
# load must either name its roles in workflow_roles or say, in its own YAML,
# `public: true`.
my $test_db = Test::Registry::DB->new;
$ENV{DB_URL} = $test_db->uri;
my $app = Test::Registry::Mojo->new('Registry')->app;

use Test::Registry::WorkflowRoleCoverage;
use File::Temp;

my $roles = sub ($slug) { $app->workflow_roles($slug) };

subtest 'every shipped workflow has a role entry or the public mark' => sub {
    my $dir = Mojo::Home->new->child('workflows');
    ok scalar $dir->list->grep(qr/\.ya?ml\z/)->each, 'there are workflow files to check';
    is_deeply [ Test::Registry::WorkflowRoleCoverage::problems( $dir, $roles ) ], [],
      'and none of them is uncovered, contradictory or unreadable';
};

# The checks below run the same helper over workflows written for the purpose,
# against a fixed role map, so each rule is exercised on its own.
my %FIXTURE_ROLES = ( 'guarded-flow' => ['admin'] );
my $fixture_roles = sub ($slug) { $FIXTURE_ROLES{$slug} };

sub problems_for (%files) {
    my $dir = File::Temp->newdir;
    for my $name ( keys %files ) {
        open my $fh, '>', "$dir/$name" or die $!;
        print $fh $files{$name};
        close $fh;
    }
    return [ Test::Registry::WorkflowRoleCoverage::problems( "$dir", $fixture_roles ) ];
}

sub workflow_yaml ( $slug, %extra ) {
    my $yaml = "name: $slug\nslug: $slug\ndescription: fixture\n";
    $yaml .= "$_: $extra{$_}\n" for sort keys %extra;
    return $yaml . "steps:\n  - slug: only\n    description: x\n";
}

subtest 'a workflow with no role entry and no public mark is reported by file and slug' => sub {
    my $problems = problems_for( 'forgotten.yml' => workflow_yaml('forgotten-flow') );
    is scalar @$problems, 1, 'one problem';
    like $problems->[0], qr/forgotten\.yml/,    'naming the file';
    like $problems->[0], qr/forgotten-flow/,    'and the slug';
    like $problems->[0], qr/no workflow_roles entry and no public mark/, 'and what is wrong';
};

subtest 'only a yaml boolean true counts as the public mark' => sub {
    is_deeply problems_for( 'a.yml' => workflow_yaml( 'a-flow', public => 'true' ) ), [],
      'public: true is the mark';
    for my $not_the_mark ( 'false', '"true"', '1', 'yes' ) {
        my $problems = problems_for( 'b.yml' => workflow_yaml( 'b-flow', public => $not_the_mark ) );
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

subtest 'a workflow with both a role entry and the public mark fails as contradictory' => sub {
    my $problems =
      problems_for( 'guarded.yml' => workflow_yaml( 'guarded-flow', public => 'true' ) );
    is scalar @$problems, 1, 'one problem';
    like $problems->[0], qr/guarded\.yml.*guarded-flow/, 'naming the file and slug';
    like $problems->[0], qr/contradict/, 'as contradictory';
};

done_testing;
