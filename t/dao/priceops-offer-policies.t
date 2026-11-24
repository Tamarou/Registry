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

subtest 'version offers one time and percentage plans by id' => sub {
    my $offer = new_offer('Pottery membership');
    my $draft = $offer->draft( $db, offer_terms( $seat->id,
        payment_plans => [
            { id => 'pay-once', kind => 'one_time' },
            { id => 'share',    kind => 'percentage_of_sales', fraction => 0.025 },
        ] ) );

    my $v = Registry::DAO::OfferVersion->find( $db, { id => $draft->id } );
    my %plans = map { $_->{id} => $_ } $v->payment_plans($db)->@*;
    is_deeply [ sort keys %plans ], [ 'pay-once', 'share' ], 'both plans are offered, each by its id';
    is $plans{'pay-once'}{kind}, 'one_time', 'one is a one-time payment';
    ok !defined $plans{'pay-once'}{fraction}, 'which takes no fraction';
    is $plans{share}{kind},     'percentage_of_sales', 'the other a percentage of sales';
    is $plans{share}{fraction}, '0.025',               'at exactly 0.025';

    for my $bad ( 0.02505, -0.01, 1.0001 ) {
        throws_ok {
            $offer->draft( $db, offer_terms( $seat->id,
                payment_plans => [ { id => 'share', kind => 'percentage_of_sales', fraction => $bad } ] ) )
        } qr/offer_version_payment_plans_fraction_check/, "a fraction of $bad is refused";
    }
};

done_testing;
