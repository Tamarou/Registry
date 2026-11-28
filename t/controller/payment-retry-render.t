#!/usr/bin/env perl
# ABOUTME: A declined card on the session cart's payment page shows the decline's reason and offers to pay again,
# ABOUTME: and paying again renders a fresh card form for a new intent.
use 5.42.0;
use warnings;
use utf8;
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Registry;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( authenticate_as import_all_workflows days_from_now );
use Test::Registry::PricingProbe qw( state_platform_terms );
use Test::Registry::Sessions qw( make_session session_offer held_cart );
use Registry::DAO::FamilyMember;
use Registry::Service::Stripe;
use Mojo::Promise;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
$ENV{DB_URL} = $test_db->uri;
import_all_workflows($dao);

my $seller = Test::Registry::Fixtures::platform_seller($db);
$db->query( q{UPDATE registry.tenants SET stripe_charges_enabled = TRUE, stripe_details_submitted = TRUE
               WHERE slug = ?}, $seller );
state_platform_terms( $db, $seller, { rate => 0 } );
local $ENV{STRIPE_SECRET_KEY} = 'sk_test_placeholder_not_real';

my $t = Test::Registry::Mojo->new('Registry');
$t->ua->max_redirects(5);

# The parent the run belongs to: a run answers only to its own user.
my $parent = Test::Registry::Fixtures::create_user( $dao, { username => 'retry_parent', name => 'Retry Parent',
    email => 'retry_parent@example.com', user_type => 'parent' } );
authenticate_as( $t, $parent );
my $kid = Registry::DAO::FamilyMember->create( $db, { family_id => $parent->id, child_name => 'Kid', birth_date => '2016-01-01' } );

my $s = make_session( $db, days => [ map { days_from_now($_) } 30 .. 32 ] );
my ($run) = held_cart( $dao, $parent->id, [ $kid->id, $s->id, session_offer( $db, $s, price_cents => 10000 )->id, 'pay' ] );
my $url = "/session-checkout/@{[ $run->id ]}/payment";

my @secrets;
no warnings 'redefine';
local *Registry::Service::Stripe::create_payment_intent_async = sub ( $self, $p ) {
    push @secrets, 'pi_secret_' . ( @secrets + 1 );
    Mojo::Promise->resolve( { id => 'pi_try_' . @secrets, client_secret => $secrets[-1] } );
};
# Paying again after a decline cancels the declined intent first.
local *Registry::Service::Stripe::cancel_payment_intent_async = sub ( $self, $id, $key = undef ) {
    Mojo::Promise->resolve( { id => $id, status => 'canceled' } );
};
local *Registry::Service::Stripe::retrieve_payment_intent_async = sub ( $self, $id ) {
    Mojo::Promise->resolve( { id => $id, status => 'requires_payment_method',
        last_payment_error => { message => 'Your card was declined.' } } );
};

subtest 'a declined card shows its reason and offers to pay again' => sub {
    $t->post_ok($url)->status_is(200)
      ->content_like( qr/pi_secret_1/, 'the first card form is for the first intent' );

    $t->get_ok("$url?payment_intent=pi_try_1&redirect_status=failed")->status_is(200)
      ->element_exists( '.alert-error', 'a banner' )
      ->content_like( qr/Your card was declined\./, 'giving the decline reason' )
      ->element_exists( 'form button[type="submit"]', 'and a way to pay again' );
};

subtest 'paying again renders a fresh card form' => sub {
    $t->post_ok($url)->status_is(200)
      ->content_like( qr/pi_secret_2/, 'the new intent\'s client secret reaches the JS init' )
      ->content_unlike( qr/pi_secret_1/, 'not the declined one' );
};

done_testing();
