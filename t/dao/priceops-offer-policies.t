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

# A draft of a new offer with %terms over the defaults, read back from the database.
sub drafted ( $name, %terms ) {
    my $draft = new_offer($name)->draft( $db, offer_terms( $seat->id, %terms ) );
    return Registry::DAO::OfferVersion->find( $db, { id => $draft->id } );
}

subtest 'day one policy shapes stored as data' => sub {
    my %day_one = (
        change => { kind => 'window', window_hours => 48, fee_cents => 1000, targets => 'same_offer' },
        use    => { kind => 'optional_attendance' },
        expiry => { kind => 'occurrence_end' },
    );
    for my $refund (
        { kind => 'none' },
        { kind => 'full_until_cutoff', cutoff_hours => 24 },
        { kind => 'full_until_cutoff', cutoff_at => '2027-01-15T00:00:00Z' },
        { kind => 'keep_fee_with_admin_exception' },
    ) {
        my $policies = { %day_one, refund => $refund };
        my $v = drafted( "Refund $refund->{kind}", policies => $policies );
        is_deeply $v->policies, $policies, "refund $refund->{kind} round-trips with change, use and expiry";
    }
    is_deeply drafted( 'No changes', policies => { change => { kind => 'none' } } )->policies,
        { change => { kind => 'none' } }, 'a change policy can allow no change';
};

subtest 'refund policy vocabulary is pinned' => sub {
    for my $kind (qw( full_until keep_fee refund_all )) {
        throws_ok { drafted( "Refund $kind", policies => { refund => { kind => $kind } } ) }
            qr/unknown refund policy kind '$kind'/, "refund policy '$kind' is refused";
    }
    throws_ok { drafted( 'Transfer', policies => { transfer => { kind => 'none' } } ) }
        qr/unknown policy 'transfer'/, 'an unknown kind of policy is refused';

    my $v = drafted( 'Raw SQL', policies => { refund => { kind => 'none' } } );
    throws_ok {
        $db->query( q{UPDATE offer_versions SET policies = '{"refund": {"kind": "keep_fee"}}' WHERE id = ?}, $v->id )
    } qr/offer_versions_refund_kind_check/, 'and the database refuses it from raw SQL too';
};

subtest 'sibling condition declared as data' => sub {
    my $program = new_offer('After-school pottery');
    my $sibling = { kind => 'family_holds_entitlement', offer_id => $program->id };
    my $v = drafted( 'Sibling rate', conditions => [$sibling] );
    is_deeply $v->conditions, [$sibling],
        "the condition 'holder's family holds an entitlement to the program' round-trips";
    is_deeply drafted('No conditions')->conditions, [], 'a version without conditions has none';
};

subtest 'published policies and plans are immutable' => sub {
    my $program = new_offer('Camp week');
    my $offer   = new_offer('Camp sibling rate');
    my $v = $offer->draft( $db, offer_terms( $seat->id,
        payment_plans => [ { id => 'share', kind => 'percentage_of_sales', fraction => 0.025 } ],
        policies      => { refund => { kind => 'none' } },
        conditions    => [ { kind => 'family_holds_entitlement', offer_id => $program->id } ],
    ) )->publish($db);
    my $refused = qr/offer \Q@{[ $offer->id ]}\E version 1/;

    throws_ok {
        $db->query( q{UPDATE offer_versions SET policies = '{"refund": {"kind": "keep_fee_with_admin_exception"}}' WHERE id = ?}, $v->id )
    } $refused, 'changing a published refund policy is refused';
    throws_ok {
        $db->query( q{UPDATE offer_versions SET conditions = '[]' WHERE id = ?}, $v->id )
    } $refused, 'changing a published condition is refused';
    throws_ok {
        $db->query( 'UPDATE offer_versions SET price_cents = 1 WHERE id = ?', $v->id )
    } $refused, 'changing a published price is refused';
    throws_ok {
        $db->query( 'UPDATE offer_version_payment_plans SET fraction = 0.03 WHERE offer_version_id = ?', $v->id )
    } $refused, 'changing a published payment plan is refused';
    is $v->payment_plans($db)->[0]{fraction}, '0.025', 'and the plan is unchanged';
};

done_testing;
