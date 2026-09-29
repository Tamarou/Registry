#!/usr/bin/env perl
# ABOUTME: An applicant may choose their web address, and is told when the one they chose is gone.
# ABOUTME: A derived slug silently became name_1, so a squatted name looked like one nobody wanted (#443).

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use experimental qw(defer signatures);
use Test::More import => [qw( done_testing is isnt ok like unlike subtest diag )];
defer { done_testing };

use Test::Registry::Mojo;
use Test::Registry::DB;
use Registry::DAO::Tenant;

my $t_db = Test::Registry::DB->new;
my $dao  = $t_db->db;
my $db   = $dao->db;
$ENV{DB_URL} = $t_db->uri;

$dao->import_workflows(['workflows/tenant-signup.yml']);

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper( dao => sub { $dao } );
$dao->current_tenant('registry');

subtest 'the profile step asks for a web address, optionally' => sub {
    my $template = Mojo::File->new('templates/tenant-signup/profile.html.ep')->slurp;
    like $template, qr/name="subdomain"/, 'there is a field for it';
    like $template, qr/leave blank/i,
        'and it says it may be left blank, because the name usually derives one';
};

subtest 'the availability check answers about what was typed' => sub {
    $t->post_ok( '/tenant-signup/validate-subdomain' => form => {
        name => 'Clay And Kiln', subdomain => 'clay' } )->status_is(200)
      ->content_like( qr/>clay</, 'the typed address, not one derived from the name' )
      ->content_like( qr/Available/, 'and it is free' );
};

subtest 'a reserved address is refused by name' => sub {
    $t->post_ok( '/tenant-signup/validate-subdomain' => form => { subdomain => 'www' } )
      ->status_is(200)
      ->content_like( qr/Reserved/i, 'said to be reserved' )
      ->content_unlike( qr/Available/, 'and not offered' );
};

# Walks the funnel with a chosen address, then again with the same one.
sub sign_up ( $name, $subdomain ) {
    $t->post_ok('/tenant-signup')->status_is(302);
    my $url = $t->tx->res->headers->location;
    $t->get_ok($url)->status_is(200);

    $t->post_ok( $url => form => {
        name => $name, billing_email => 'owner@choose.example',
        subdomain => $subdomain,
    } )->status_is(302);
    $url = $t->tx->res->headers->location;
    $t->get_ok($url)->status_is(200);

    my $user = lc( $name =~ s/\W+/_/gr );
    $t->post_ok( $url => form => {
        admin_name => "Admin $name", admin_email => "$user\@choose.example",
        admin_username => $user, admin_user_type => 'admin',
    } )->status_is(302);
    my $review = $t->tx->res->headers->location;
    $t->get_ok($review)->status_is(200);
    $t->post_ok( $review => form => { terms_accepted => 1 } );
    return $review;
}

subtest 'the address the applicant chose is the one they get' => sub {
    my $review = sign_up( 'Clay And Kiln', 'clay' );
    $t->status_is(302);

    my $row = $db->query(
        'SELECT slug FROM registry.tenants WHERE name = ?', 'Clay And Kiln' )->hash;
    ok $row, 'the tenant was provisioned';
    is $row->{slug}, 'clay',
        'as clay -- not clay_and_kiln derived from the name';
};

subtest 'the next applicant to want it is told, not silently suffixed' => sub {
    my $review = sign_up( 'Clay Collective', 'clay' );

    ok !$db->query(
        'SELECT 1 FROM registry.tenants WHERE name = ?', 'Clay Collective' )->hash,
        'no tenant was created';

    # The whole point of #443's UX half. Silently provisioning clay_1 is what
    # made a squatted name look like a name nobody wanted: the applicant never
    # learned they could pick another.
    ok !$db->query( 'SELECT 1 FROM registry.tenants WHERE slug = ?', 'clay_1' )->hash,
        'and certainly not as clay_1';

    $t->status_is(302);
    $t->get_ok($review)->status_is(200)
      ->content_like( qr/already taken/i, 'the applicant is told it is taken' )
      ->content_like( qr/clay/, 'and which address is the problem' );
};

subtest 'leaving it blank still derives one, suffixed if it must be' => sub {
    sign_up( 'Clay', '' );
    $t->status_is(302);

    my $row = $db->query(
        'SELECT slug FROM registry.tenants WHERE name = ?', 'Clay' )->hash;
    ok $row, 'the tenant was provisioned';
    is $row->{slug}, 'clay_1',
        'suffixed, because nobody chose it and a dead end would be worse';
};

$t_db->cleanup_test_database;
