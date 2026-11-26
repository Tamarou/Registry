#!/usr/bin/env perl
# ABOUTME: /terms is served anonymously on the apex and every tenant host, and signup's link to it resolves.
# ABOUTME: The page states perigrin's terms (Tamarou LLC, effective 2026-11-26) with their version marker, and no DRAFT banner.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use experimental qw(defer signatures);
use Test::More import => [qw( done_testing is ok like unlike subtest )];
defer { done_testing };

use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::Terms;

my $t_db = Test::Registry::DB->new;
my $dao  = $t_db->db;
$ENV{DB_URL}                = $t_db->uri;
$ENV{REGISTRY_BASE_DOMAINS} = 'tinyartempire.com,localhost';

$dao->import_workflows( ['workflows/tenant-signup.yml'] );

Test::Registry::Fixtures::create_tenant( $dao, { name => 'Acme Pottery',  slug => 'acme' } );
Test::Registry::Fixtures::create_tenant( $dao, { name => 'Bravo Ceramics', slug => 'bravo' } );

my $t = Test::Registry::Mojo->new('Registry');

sub is_terms_page ( $t, $label ) {
    $t->status_is( 200, "$label: 200" )
      ->element_exists( 'h1', "$label: has a heading" )
      ->text_like( 'h1' => qr/Terms of Service/, "$label: the terms heading" );
}

subtest 'terms served anonymously on the apex' => sub {
    $t->get_ok('/terms');
    is_terms_page( $t, 'apex' );
};

subtest 'terms served anonymously on a tenant host' => sub {
    $t->get_ok( '/terms' => { Host => 'acme.localhost' } );
    is_terms_page( $t, 'tenant host' );
};

subtest 'signup review page link to terms resolves' => sub {
    my $s = Test::Registry::Mojo->new('Registry');
    $s->post_ok('/tenant-signup')->status_is(302);
    my $url = $s->tx->res->headers->location;
    $s->post_ok( $url => form => { name => 'Terms Studio', billing_email => 'owner@terms.example' } )
      ->status_is(302);
    $url = $s->tx->res->headers->location;
    $s->post_ok( $url => form => {
        admin_name     => 'Terms Admin', admin_email => 'admin@terms.example',
        admin_username => 'terms_admin', admin_user_type => 'admin',
    } )->status_is(302);
    $s->get_ok( $s->tx->res->headers->location )->status_is(200);

    my $link = $s->tx->res->dom->find('a')->first( sub { $_->text =~ /Terms of Service/ } );
    ok $link, 'the review page links the terms';
    $s->get_ok( $link->attr('href') );
    is_terms_page( $s, 'followed link' );
};

subtest 'terms page states the final terms' => sub {
    is Registry::Terms::VERSION, '2026-11-26', 'the terms in force are the version effective 2026-11-26';
    $t->get_ok('/terms')->status_is(200)
      ->element_exists( q{[data-terms-version="2026-11-26"]}, 'the page carries that version marker' )
      ->element_exists_not( '.notification.warning', 'no DRAFT banner' );
    my $text = $t->tx->res->dom->at('article')->all_text =~ s/\s+/ /gr;
    unlike $text, qr/\bDRAFT\b/, 'the page does not call itself a draft';
    like $text, qr/Tamarou LLC/,                 'it names the operator';
    like $text, qr/2\.5% of each sale/,          "it states Solo's fee";
    like $text, qr/laws of the State of Florida/, 'it names the governing law';
    like $text, qr/18 or older/,                 'it states the minimum age';
    like $text, qr/registry\@tamarou\.com/,      'it gives the contact address';
    like $text, qr/429 Hoffer Ave/,              'and the postal address';
};

subtest 'post to terms is not a server error' => sub {
    # With a CSRF token, so what answers is the route, not the CSRF guard.
    my $p = Test::Registry::Mojo->new('Registry');
    $p->post_ok('/terms');
    my $code = $p->tx->res->code;
    ok $code == 404 || $code == 405, "POST /terms is 404 or 405 (got $code)";
};

subtest 'terms served with stale session cookie' => sub {
    my $s = Test::Mojo->new('Registry');
    $s->get_ok( '/terms' => { Cookie => 'mojolicious=stale--0123456789abcdef' } );
    is_terms_page( $s, 'stale cookie' );
};

subtest 'terms on one tenant host show no other tenant terms' => sub {
    $t->get_ok( '/terms' => { Host => 'acme.localhost' } )->status_is(200);
    my $body = $t->tx->res->text;
    unlike $body, qr/Bravo/i, 'no other tenant is named';
    unlike $body, qr/Acme Pottery/, 'not even this tenant: the page states the platform terms only';
};
