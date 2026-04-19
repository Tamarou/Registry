#!/usr/bin/env perl
# ABOUTME: Controller tests for location-management workflow end-to-end.
# ABOUTME: Exercises list + new + details + contact flow over HTTP.
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
use Registry::DAO::Location;
use Registry::DAO::User;
use Mojo::Home;
use YAML::XS qw(Load);

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

# Load workflows including the one we just added.
my @files = Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;
for my $file (@files) {
    next if Load($file->slurp)->{draft};
    Workflow->from_yaml($dao, $file->slurp);
}

my $t = Test::Registry::Mojo->new('Registry');
$t->ua->max_redirects(5);

my $admin = $dao->create(User => {
    username  => 'loc_admin',
    name      => 'Admin',
    email     => 'loc@test.local',
    user_type => 'admin',
    password  => 'x',
});
authenticate_as($t, $admin);

subtest 'list view shows empty state and Create button' => sub {
    $t->get_ok('/location-management')
      ->status_is(200)
      ->content_like(qr/Locations/,              'page heading')
      ->content_like(qr/Create New Location/,    'create button present');
};

subtest 'full create flow with inline new-user contact' => sub {
    # Step 1: click Create New
    my $body = $t->get_ok('/location-management')->tx->res->body;
    my ($action) = $body =~ m{action="([^"]*list-or-create[^"]*)"};
    ok($action, 'found list-or-create action');

    $t->post_ok($action => form => { action => 'new' })
      ->status_is(200)
      ->content_like(qr/New Location/, 'landed on details form');

    # Step 2: submit details
    $body = $t->tx->res->body;
    ($action) = $body =~ m{action="([^"]*location-details[^"]*)"};
    ok($action, 'found details action');

    $t->post_ok($action => form => {
        name           => 'Riverside School',
        street_address => '100 River Rd',
        city           => 'Orlando',
        state          => 'FL',
        postal_code    => '32819',
        capacity       => 20,
    })->status_is(200)
      ->content_like(qr/Contact Person/, 'landed on contact form');

    # Step 3: create a new contact user inline
    $body = $t->tx->res->body;
    ($action) = $body =~ m{action="([^"]*select-contact[^"]*)"};
    ok($action, 'found contact action');

    $t->post_ok($action => form => {
        contact_mode  => 'new',
        contact_name  => 'Pat the Principal',
        contact_email => 'pat@riverside.local',
    })->status_is(200)
      ->content_like(qr/saved/i, 'complete page reached');

    # Verify DB state.
    my $loc = Registry::DAO::Location->find($dao->db, { name => 'Riverside School' });
    ok($loc, 'location created');
    is($loc->capacity, 20, 'capacity stored');
    ok($loc->contact_person_id, 'contact_person_id set');

    my $user = Registry::DAO::User->find($dao->db, { id => $loc->contact_person_id });
    is($user->email, 'pat@riverside.local', 'contact user was created inline');
};

done_testing();
