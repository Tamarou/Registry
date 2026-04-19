#!/usr/bin/env perl
# ABOUTME: Controller tests for program-type-management workflow end-to-end.
# ABOUTME: Hits the public URLs and verifies list and create flows render.
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
use Registry::DAO::ProgramType;
use Mojo::Home;
use YAML::XS qw(Load);
use Mojo::JSON qw(encode_json);

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

# Import workflows from the repo (the one we just added is included).
my @files = Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;
for my $file (@files) {
    next if Load($file->slurp)->{draft};
    Workflow->from_yaml($dao, $file->slurp);
}

my $t = Test::Registry::Mojo->new('Registry');

my $admin = $dao->create(User => {
    username => 'ptm_admin',
    name     => 'Admin',
    email    => 'ptm@test.local',
    user_type => 'admin',
    password => 'x',
});
authenticate_as($t, $admin);

# Seed a program type so the list has something.
Registry::DAO::ProgramType->create($dao->db, {
    name   => 'Seeded Type',
    slug   => 'seeded-type',
    config => encode_json({ description => 'pre-existing' }),
});

subtest 'list view shows existing types and a create button' => sub {
    $t->get_ok('/program-type-management')
      ->status_is(200)
      ->content_like(qr/Seeded Type/,            'existing type listed')
      ->content_like(qr/pre-existing/,           'description shown')
      ->content_like(qr/Create New Program Type/,'create button present');
};

# POST to a workflow step redirects to GET of the next step, so we follow.
$t->ua->max_redirects(5);

subtest 'clicking Create New lands on the details form' => sub {
    my $body = $t->get_ok('/program-type-management')->tx->res->body;
    # The workflow_process_step URL has list-or-create in the path.
    my ($action) = $body =~ m{action="([^"]*list-or-create[^"]*)"};
    ok($action, 'found list-or-create form action');

    $t->post_ok($action => form => { action => 'new' })
      ->status_is(200)
      ->content_like(qr/New Program Type/, 'details form title');
};

subtest 'submitting details creates a program type' => sub {
    $t->post_ok('/program-type-management' => form => { action => 'new' })
      ->status_is(200);

    # Find the form by the type-details URL marker in its action attribute.
    my $body = $t->tx->res->body;
    my ($action) = $body =~ m{<form[^>]*action="([^"]*type-details[^"]*)"};
    ok($action, 'found details form action') or diag($body);

    $t->post_ok($action => form => {
        name             => 'Art Class',
        description      => 'Creative arts programs',
        session_pattern  => 'weekly',
        default_capacity => 12,
    })->status_is(200)
      ->content_like(qr/saved/i, 'complete page reached');

    my $created = Registry::DAO::ProgramType->find_by_slug($dao->db, 'art-class');
    ok($created, 'program type created in DB');
    is($created->name, 'Art Class', 'name matches');
    is($created->session_pattern, 'weekly', 'config stored');
};

done_testing();
