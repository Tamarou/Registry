#!/usr/bin/env perl
# ABOUTME: An offer version's price, units, payment plans, policies and conditions, stored as declared data.
# ABOUTME: Day-one shapes round-trip; unknown or malformed shapes are refused; all are immutable once published.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use Test::Registry::DB;
use Test::Registry::Offers qw( offer_terms );
use Registry::DAO::Resource;
use Registry::DAO::Offer;
use Registry::DAO::OfferVersion;

my $test_db = Test::Registry::DB->new;
my $db      = $test_db->db->db;

my $seat = Registry::DAO::Resource->create( $db,
    { name => 'Seat', kind => 'finite', capacity => 8 } );

sub new_offer ($name) { Registry::DAO::Offer->create( $db, { name => $name } ) }

subtest 'version stores price units and booking cap' => sub {
    my $offer = new_offer('Couples wheel night');
    my $draft = $offer->draft( $db, offer_terms( $seat->id,
        price_cents => 4500, units_per_acceptance => 2, per_booking_cap => 3 ) );

    my $v = Registry::DAO::OfferVersion->find( $db, { id => $draft->id } );
    is $v->price_cents,          4500, 'the price is stored in the smallest currency unit';
    is $v->units_per_acceptance, 2,    'one acceptance buys two seats';
    is $v->per_booking_cap,      3,    'and one booking may take at most three';
};

done_testing;
