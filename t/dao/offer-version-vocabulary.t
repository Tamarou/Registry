#!/usr/bin/env perl
# ABOUTME: The policy and condition vocabulary an offer version declares: approval, change targets and price
# ABOUTME: difference, make-ups, missed payment, sibling and early-bird. Each shape is exact; the rest is refused.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Offers qw( offer_terms );
use Registry::DAO::Resource;
use Registry::DAO::Offer;
use Registry::DAO::OfferVersion;

my $test_db = Test::Registry::DB->new;
my $db      = $test_db->db->db;

my $seat = Registry::DAO::Resource->create( $db, { name => 'Seat', kind => 'finite', capacity => 8 } );
my $o1   = Registry::DAO::Offer->create( $db, { name => 'Autumn term' } )->id;
my $o2   = Registry::DAO::Offer->create( $db, { name => 'Make-up class' } )->id;

# Whether a draft declaring %terms is accepted, through the real draft path.
my $n = 0;
sub accepted (%terms) {
    my $offer = Registry::DAO::Offer->create( $db, { name => 'Vocabulary ' . ++$n } );
    return eval { $offer->draft( $db, offer_terms( $seat->id, %terms ) ); 1 };
}
sub ok_policy ( $name, $policy ) { accepted( policies => { $name => $policy } ) }
sub ok_condition ($condition)    { accepted( conditions => [$condition] ) }

my $window = { kind => 'window', window_hours => 48, fee_cents => 0, targets => 'same_offer' };

subtest 'every refund kind is accepted with or without approval' => sub {
    for my $refund (
        { kind => 'none' },
        { kind => 'full_until_cutoff', cutoff_hours => 24 },
        { kind => 'full_until_cutoff', cutoff_at => '2027-01-15T00:00:00Z' },
        { kind => 'keep_fee_with_admin_exception' },
    ) {
        my $what = join ' ', map { "$_=$refund->{$_}" } sort keys %$refund;
        ok ok_policy( refund => $refund ), "$what without approval";
        ok ok_policy( refund => { %$refund, approval => $_ } ), "$what with approval $_" for qw( required none );
    }
};

subtest 'change window accepts targets, price difference and approval' => sub {
    ok ok_policy( change => { kind => 'none' } ), 'none';
    ok ok_policy( change => { %$window, targets => $_ } ), "targets $_" for qw( same_offer same_program );
    ok ok_policy( change => { %$window, targets => { offer_ids => [ $o1, $o2 ] } } ), 'targets a list of offers';
    ok ok_policy( change => { %$window, price_difference => $_ } ), "price difference $_"
        for qw( charge_and_refund charge_only same_price_only );
    ok ok_policy( change => { %$window, approval => $_ } ), "approval $_" for qw( required none );
    ok ok_policy( change => { kind => 'window', window_hours => 0, fee_cents => 0,
        targets => { offer_ids => [$o1] }, price_difference => 'charge_only', approval => 'required' } ),
        'all of them at once';
};

subtest 'use accepts makeup with credit days and optional max per term' => sub {
    ok ok_policy( use => { kind => $_ } ), "use $_" for qw( optional_attendance none );
    ok ok_policy( use => { kind => 'makeup', offer_id => $o2, credit_days => 30 } ), 'makeup without a cap';
    ok ok_policy( use => { kind => 'makeup', offer_id => $o2, credit_days => 30, max_per_term => 2 } ),
        'makeup with a cap per term';
};

subtest 'missed_payment accepts keep_and_owe, end and grace' => sub {
    ok ok_policy( missed_payment => { kind => $_ } ), "missed_payment $_" for qw( keep_and_owe end );
    ok ok_policy( missed_payment => { kind => 'grace', days => 7 } ), 'grace for 7 days';
};

subtest 'conditions accept family_holds_entitlement, before and holder_is_offerer' => sub {
    ok ok_condition( { kind => 'family_holds_entitlement' } ), 'offer_ids is optional';
    ok ok_condition( { kind => 'family_holds_entitlement', offer_ids => [ $o1, $o2 ] } ), 'or names the offers that count';
    ok ok_condition( { kind => 'before', at => '2027-03-01T00:00:00-05:00' } ), 'before an instant';
    ok ok_condition( { kind => 'holder_is_offerer' } ), 'holder_is_offerer';
};

subtest 'absent approval reads as none and absent price difference as same_price_only' => sub {
    is( Registry::DAO::OfferVersion->approval_for( { kind => 'none' } ), 'none', 'absent approval is none' );
    is( Registry::DAO::OfferVersion->approval_for( { kind => 'none', approval => 'required' } ), 'required',
        'a stated approval is read as stated' );
    is( Registry::DAO::OfferVersion->price_difference_for($window), 'same_price_only',
        'absent price difference is same_price_only' );
    is( Registry::DAO::OfferVersion->price_difference_for( { %$window, price_difference => 'charge_only' } ),
        'charge_only', 'a stated price difference is read as stated' );
};

done_testing;
