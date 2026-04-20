#!/usr/bin/env perl
# ABOUTME: Controller tests for the program-setup orchestrator.
# ABOUTME: Exercises the overview page and verifies callcc-into-sub-workflow works.
use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Registry;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw(authenticate_as);
use Registry::DAO qw(Workflow);
use Mojo::Home;
use YAML::XS qw(Load);

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

# Import all workflows so the sub-workflow slugs the orchestrator calls
# into actually resolve.
my @files = Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;
for my $file (@files) {
    next if Load($file->slurp)->{draft};
    Workflow->from_yaml($dao, $file->slurp);
}

my $t = Test::Registry::Mojo->new('Registry');
$t->ua->max_redirects(5);

my $admin = $dao->create(User => {
    username  => 'setup_admin',
    name      => 'Admin',
    email     => 'setup@test.local',
    user_type => 'admin',
    password  => 'x',
});
authenticate_as($t, $admin);

subtest 'overview page renders the checklist' => sub {
    $t->get_ok('/program-setup')
      ->status_is(200)
      ->content_like(qr/Program Setup/,       'heading')
      ->content_like(qr/Program Types/,       'program types item')
      ->content_like(qr/Locations/,           'locations item')
      ->content_like(qr/Programs/,            'programs item')
      ->content_like(qr/Sessions/,            'sessions item')
      ->content_like(qr/Pricing/,             'pricing item');
};

subtest 'checklist items post to callcc URLs' => sub {
    my $body = $t->get_ok('/program-setup')->tx->res->body;
    for my $target (qw(
        program-type-management
        location-management
        program-creation
        program-location-assignment
        pricing-plan-creation
    )) {
        like($body, qr{callcc/\Q$target\E},
             "$target appears as a callcc target");
    }
};

subtest 'callcc into program-type-management suspends orchestrator' => sub {
    # Fresh overview page to get a run id.
    my $body = $t->get_ok('/program-setup')->tx->res->body;
    my ($action) = $body =~ m{action="([^"]*callcc/program-type-management[^"]*)"};
    ok($action, 'found callcc form action');

    # POSTing the callcc form starts a new child run and redirects to its
    # first step. Test::Mojo follows redirects so we should land on the
    # sub-workflow's first step.
    $t->post_ok($action => form => {})
      ->status_is(200)
      ->content_like(qr/Program Types/i, 'landed inside sub-workflow');
};

subtest 'counts update when admin returns to overview after setup' => sub {
    # Capture the starting count of program types (test DB comes with
    # seed data, so the count isn't guaranteed to be zero).
    my $start_count = $dao->db->query('SELECT COUNT(*) FROM program_types')->array->[0];

    # Walk the sub-workflow to completion: callcc -> list -> new -> details.
    my $body = $t->get_ok('/program-setup')->tx->res->body;
    my ($callcc) = $body =~ m{action="([^"]*callcc/program-type-management[^"]*)"};
    $t->post_ok($callcc => form => {});
    my ($list_action) = $t->tx->res->body =~ m{action="([^"]*list-or-create[^"]*)"};
    $t->post_ok($list_action => form => { action => 'new' });
    my ($details_action) = $t->tx->res->body =~ m{action="([^"]*type-details[^"]*)"};
    $t->post_ok($details_action => form => {
        name             => 'Return-Path Type',
        description      => 'Created via orchestrator',
        session_pattern  => 'weekly',
        default_capacity => 10,
    })->status_is(200);

    # Confirm the new type landed in the DB.
    my $end_count = $dao->db->query('SELECT COUNT(*) FROM program_types')->array->[0];
    is($end_count, $start_count + 1, 'one new program type created');

    # Manually come back to the orchestrator (simulating Victoria using
    # the nav link or a bookmark). The overview should reflect the new
    # count for program types.
    $t->get_ok('/program-setup')
      ->status_is(200)
      ->content_like(qr/Program Types.*\(\Q$end_count\E\)/s,
                     'overview shows updated program type count');
};

done_testing();
