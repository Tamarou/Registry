#!/usr/bin/env perl
# ABOUTME: The policy and condition vocabulary an offer version declares: approval, change targets and price
# ABOUTME: difference, make-ups, missed payment, sibling and early-bird. Each shape is exact; the rest is refused.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use Mojo::File qw( path );
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

subtest 'each policy refuses an unknown field, a wrong type and a missing required field' => sub {
    my $makeup = { kind => 'makeup', offer_id => $o2, credit_days => 30 };
    my $cutoff = { kind => 'full_until_cutoff', cutoff_hours => 24 };
    my %bad = (
        refund => [
            [ { %$cutoff, approve => 'required' }, 'an unknown field' ],
            [ { %$cutoff, approval => 'maybe' },   'approval that is neither required nor none' ],
            [ { %$cutoff, approval => undef },     'an approval stated as null' ],
            [ { kind => 'full_until_cutoff', approval => 'none' }, 'full_until_cutoff with no cutoff' ],
        ],
        change => [
            [ { %$window, fee => 0 },                           'an unknown field' ],
            [ { %$window, fee_cents => 'ten' },                 'a fee that is not whole' ],
            [ { %$window, targets => 'any_offer' },             'an unknown target' ],
            [ { %$window, targets => { offer_ids => ['x'] } },   'targets that are not offer ids' ],
            [ { %$window, targets => { offer_ids => [$o1], program => 1 } }, 'targets with an unknown field' ],
            [ { %$window, price_difference => 'refund_only' },  'an unknown price difference' ],
            [ { %$window, approval => 1 },                      'approval that is not required or none' ],
            [ { kind => 'window', window_hours => 48, fee_cents => 0 }, 'a window with no targets' ],
        ],
        use => [
            [ { %$makeup, credit => 30 },          'an unknown field' ],
            [ { %$makeup, credit_days => 0 },      'zero credit days' ],
            [ { %$makeup, credit_days => 'a month' }, 'credit days that are not whole' ],
            [ { %$makeup, max_per_term => 0 },     'a zero cap per term' ],
            [ { %$makeup, offer_id => 'pottery' }, 'a make-up offer that is not an id' ],
            [ { kind => 'makeup', credit_days => 30 }, 'a makeup naming no offer' ],
        ],
        missed_payment => [
            [ { kind => 'end', days => 7 },     'an unknown field' ],
            [ { kind => 'grace', days => 'a week' }, 'grace days that are not whole' ],
            [ { kind => 'grace', days => 0 },   'zero grace days' ],
            [ { kind => 'grace' },              'grace with no days' ],
            [ { kind => 'cancel' },             'an unknown kind' ],
        ],
        expiry => [ [ { kind => 'never', at => '2027-01-01T00:00:00Z' }, 'an unknown field' ] ],
    );
    for my $policy ( sort keys %bad ) {
        ok !ok_policy( $policy => $_->[0] ), "$policy: $_->[1] is refused" for $bad{$policy}->@*;
    }
    ok !ok_condition( { kind => 'before' } ), 'before with no instant is refused';
    ok !ok_condition( { kind => 'before', at => 'March' } ), 'before an instant that is not one is refused';
    ok !ok_condition( { kind => 'before', at => '2027-03-01T00:00:00Z', until => 1 } ),
        'before with an unknown field is refused';

    my $draft = Registry::DAO::Offer->create( $db, { name => 'Raw missed payment' } )
        ->draft( $db, offer_terms( $seat->id ) );
    throws_ok {
        $db->query( q{UPDATE offer_versions SET policies = '{"refund": {"kind": "none"}, "missed_payment": {"kind": "cancel"}}'
                      WHERE id = ?}, $draft->id )
    } qr/offer_versions_missed_payment_kind_check/, 'and the database refuses an unknown missed_payment kind';
};

subtest 'an empty offer_ids target list is refused' => sub {
    ok !ok_policy( change => { kind => 'window', window_hours => 0, fee_cents => 0, targets => { offer_ids => [] } } ),
        'a change window targeting no offers is refused';
    ok !ok_condition( { kind => 'family_holds_entitlement', offer_ids => [] } ),
        'and so is a sibling condition naming no offers';
};

subtest 'the singular family_holds_entitlement shape is refused' => sub {
    ok !ok_condition( { kind => 'family_holds_entitlement', offer_id => $o1 } ), 'the singular shape is retired';
    ok !ok_condition( { kind => 'family_holds_entitlement', offer_id => $o1, offer_ids => [$o1] } ),
        'and is not accepted beside offer_ids';
};

subtest 'the migration refuses a published version carrying offer_id' => sub {
    my $run = sub ($change) {
        for my $step (qw( revert deploy )) {
            my $sql = path("sql/$step/$change.sql")->slurp;
            $sql =~ s/^\s*(?:BEGIN|COMMIT);\s*$//mg;
            $db->query($sql);
        }
    };
    my $tx = $db->begin;
    lives_ok { $run->('priceops-session-vocabulary') } 'it deploys over published versions without offer_id';

    # The DAO refuses the retired shape, so it is written as a pre-migration row was.
    my $offer = Registry::DAO::Offer->create( $db, { name => 'Old sibling rate' } );
    my ($v) = $db->query( q{INSERT INTO offer_versions (offer_id, version, resource_id, price_cents,
            units_per_acceptance, per_booking_cap, policies, conditions)
        VALUES (?, 1, ?, 1500, 1, 1, '{"refund":{"kind":"none"}}', ?::jsonb) RETURNING id},
        $offer->id, $seat->id, qq{[{"kind":"family_holds_entitlement","offer_id":"$o1"}]} )->array->@*;
    $db->insert( 'offer_version_payment_plans', { offer_version_id => $v, id => 'pay', kind => 'one_time' } );
    $db->query( 'UPDATE offer_versions SET published_at = now() WHERE id = ?', $v );
    $db->query('SET CONSTRAINTS ALL IMMEDIATE');    # its deferred plan check, before the ALTER

    throws_ok { $run->('priceops-session-vocabulary') }
        qr/carry a condition with offer_id.*offer \Q@{[ $offer->id ]}\E version 1/s,
        'it refuses to deploy, naming the published version';
    undef $tx;
};

done_testing;
