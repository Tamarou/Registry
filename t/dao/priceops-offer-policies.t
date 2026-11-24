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
use Mojo::Pg;
use Test::Registry::Offers qw( offer_terms );
use Registry::DAO::Resource;
use Registry::DAO::Offer;
use Registry::DAO::OfferVersion;
use Registry::DAO::Tenant;

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
        expiry => { kind => 'end_of_occurrence' },
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
    my $open = { use => { kind => 'none' }, expiry => { kind => 'never' } };
    is_deeply drafted( 'Open-ended', policies => $open )->policies, $open,
        'use none and expiry never round-trip';
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

subtest 'negative or fractional price refused' => sub {
    throws_ok { drafted( 'Negative', price_cents => -1 ) }
        qr/offer_versions_price_cents_check/, 'a negative price is refused';
    throws_ok { drafted( 'Fractional', price_cents => 1250.5 ) }
        qr/invalid input syntax for type integer/, 'a fraction of the smallest currency unit is refused';
    is drafted( 'Free', price_cents => 0 )->price_cents, 0, 'a price of exactly 0 is a price';
};

subtest 'zero units or cap refused' => sub {
    for my $field (qw( units_per_acceptance per_booking_cap )) {
        for my $bad ( 0, -1 ) {
            throws_ok { drafted( "$field $bad", $field => $bad ) }
                qr/offer_versions_${field}_check/, "$field of $bad is refused";
        }
    }
};

subtest 'publish without payment plan refused' => sub {
    my $offer = new_offer('Planless');
    my $draft = $offer->draft( $db, offer_terms( $seat->id, payment_plans => [] ) );
    throws_ok { $draft->publish($db) } qr/no payment plan/, 'a version offering no payment plan is not published';
    throws_ok {
        $db->query( 'UPDATE offer_versions SET published_at = now() WHERE id = ?', $draft->id )
    } qr/no payment plan/, 'publishing it by raw SQL is refused too';
    ok !Registry::DAO::OfferVersion->find( $db, { id => $draft->id } )->is_published, 'it stays a draft';
};

subtest 'publish without explicit refund policy refused' => sub {
    my $offer = new_offer('No refund stated');
    my $draft = $offer->draft( $db, offer_terms( $seat->id, policies => { use => { kind => 'optional_attendance' } } ) );
    throws_ok { $draft->publish($db) } qr/no refund policy/, 'a version with no refund policy is not published';
    my $v = Registry::DAO::OfferVersion->find( $db, { id => $draft->id } );
    ok !$v->is_published, 'it stays a draft';
    ok !exists $v->policies->{refund}, 'and no refund policy was filled in for it';
    throws_ok {
        $db->query( 'UPDATE offer_versions SET published_at = now() WHERE id = ?', $draft->id )
    } qr/offer_versions_published_states_refund/, 'publishing it by raw SQL is refused too';
};

subtest 'percentage boundaries enforced' => sub {
    my $offer = new_offer('Share');
    my $share = sub ($fraction) {
        $offer->draft( $db, offer_terms( $seat->id,
            payment_plans => [ { id => 'share', kind => 'percentage_of_sales', fraction => $fraction } ] ) );
    };
    for my $bad ( 0.02505, -0.01, 1.0001 ) {
        throws_ok { $share->($bad) } qr/offer_version_payment_plans_fraction_check/, "$bad is refused";
    }
    throws_ok { $share->('2.5%') } qr/invalid input syntax for type numeric/, "the string '2.5%' is refused";

    is $share->(0)->payment_plans($db)->[0]{fraction},     '0',     'exactly 0 is stored as 0, not NULL';
    is $share->(0.025)->payment_plans($db)->[0]{fraction}, '0.025', '0.025 reads back exactly';
    is $share->(1)->payment_plans($db)->[0]{fraction},     '1',     'and 1 is the upper bound';
};

subtest 'duplicate payment plan id refused' => sub {
    throws_ok {
        drafted( 'Twin plans', payment_plans => [
            { id => 'pay', kind => 'one_time' },
            { id => 'pay', kind => 'percentage_of_sales', fraction => 0.01 },
        ] )
    } qr/offer_version_payment_plans_pkey/, 'two plans with the same id on one version are refused';
};

subtest 'malformed policies refused' => sub {
    my $other = new_offer('Somewhere else');
    my $window = { kind => 'window', window_hours => 48, fee_cents => 1000, targets => 'same_offer' };
    for my $case (
        [ { refund => { kind => 'full_until_cutoff' } },                       qr/malformed refund policy 'full_until_cutoff'/, 'full_until_cutoff with no cutoff' ],
        [ { refund => { kind => 'full_until_cutoff', cutoff_hours => -1 } },   qr/malformed refund policy/, 'a negative cutoff' ],
        [ { refund => { kind => 'full_until_cutoff', cutoff_at => 'Friday' } }, qr/malformed refund policy/, 'a cutoff that is not a time' ],
        [ { refund => { kind => 'none', cutoff_hours => 24 } },                qr/malformed refund policy 'none'/, 'fields a kind does not take' ],
        [ { change => { %$window, window_hours => -1 } },                      qr/malformed change policy/, 'a negative change window' ],
        [ { change => { %$window, fee_cents => -1 } },                         qr/malformed change policy/, 'a negative change fee' ],
        [ { change => { %$window, targets => { offer_id => $other->id } } },  qr/malformed change policy/, 'change targets naming a different offer' ],
        [ { change => { %$window, fee_cents => undef } },                      qr/malformed change policy/, 'a change policy with no fee' ],
        [ { refund => 'none' },                                                qr/refund policy must be an object/, 'policy data that is not an object' ],
        [ 'refund: none',                                                      qr/policies must be an object/, 'policies that are not an object' ],
    ) {
        my ( $policies, $error, $what ) = @$case;
        throws_ok { drafted( 'Malformed', policies => $policies ) } $error, "$what is refused";
    }
    throws_ok {
        $db->query( q{UPDATE offer_versions SET policies = '"none"' WHERE id = ?}, drafted('Raw')->id )
    } qr/offer_versions_policies_object/, 'and the database refuses policies that are not an object';
};

subtest 'unknown condition kind refused' => sub {
    my $program = new_offer('Program');
    throws_ok { drafted( 'Early bird', conditions => [ { kind => 'early_bird', before => '2027-01-01' } ] ) }
        qr/unknown condition kind 'early_bird'/, 'an undeclared condition kind is refused';
    throws_ok { drafted( 'Sloppy sibling', conditions => [ { kind => 'family_holds_entitlement' } ] ) }
        qr/malformed condition 'family_holds_entitlement'/, 'a known kind missing its offer is refused';
    throws_ok { drafted( 'Not a list', conditions => { kind => 'family_holds_entitlement', offer_id => $program->id } ) }
        qr/conditions must be a list/, 'conditions that are not a list are refused';
    is $db->query( q{SELECT count(*) FROM offers o JOIN offer_versions v ON v.offer_id = o.id
                      WHERE o.name IN ('Early bird', 'Sloppy sibling', 'Not a list')} )->array->[0],
        0, 'and none of them was stored';
};

subtest 'published child data insert or delete refused' => sub {
    my $program = new_offer('Term');
    my $offer   = new_offer('Term sibling rate');
    my $v = $offer->draft( $db, offer_terms( $seat->id,
        conditions => [ { kind => 'family_holds_entitlement', offer_id => $program->id } ] ) )->publish($db);
    my $refused = qr/offer \Q@{[ $offer->id ]}\E version 1/;

    throws_ok {
        $db->query( q{INSERT INTO offer_version_payment_plans (offer_version_id, id, kind, fraction)
                      VALUES (?, 'extra', 'percentage_of_sales', 0.01)}, $v->id )
    } $refused, 'adding a payment plan to a published version is refused';
    throws_ok {
        $db->query( 'DELETE FROM offer_version_payment_plans WHERE offer_version_id = ?', $v->id )
    } $refused, 'removing one is refused';
    throws_ok {
        $db->query( q{UPDATE offer_versions SET policies = policies || '{"expiry": {"kind": "end_of_occurrence"}}' WHERE id = ?}, $v->id )
    } $refused, 'adding a policy is refused';
    throws_ok {
        $db->query( q{UPDATE offer_versions SET policies = policies - 'refund' WHERE id = ?}, $v->id )
    } $refused, 'removing one is refused';
    throws_ok {
        $db->query( q{UPDATE offer_versions SET conditions = conditions || '[{"kind": "family_holds_entitlement", "offer_id": "x"}]' WHERE id = ?}, $v->id )
    } $refused, 'adding a condition is refused';
    throws_ok {
        $db->query( q{UPDATE offer_versions SET conditions = '[]' WHERE id = ?}, $v->id )
    } $refused, 'removing one is refused';
    is scalar $v->payment_plans($db)->@*, 1, 'the published version keeps exactly its one plan';

    my $draft = $offer->draft( $db, offer_terms( $seat->id ) );
    lives_ok {
        $db->query( q{INSERT INTO offer_version_payment_plans (offer_version_id, id, kind) VALUES (?, 'extra', 'one_time')}, $draft->id );
        $db->query( q{DELETE FROM offer_version_payment_plans WHERE offer_version_id = ? AND id = 'extra'}, $draft->id );
    } "a draft's plans stay editable";
    lives_ok { $db->query( 'DELETE FROM offer_versions WHERE id = ?', $draft->id ) }
        'and discarding a draft takes its plans with it';

    # A tenant provisioned the way signup provisions one: the row, then its schema.
    Registry::DAO::Tenant->create( $db, { name => 'Studio Kiln', slug => 'kiln_co' } );
    $db->query( 'SELECT clone_schema(dest_schema => ?)', 'kiln_co' );
    my $tdb    = Registry::DAO::Tenant->find( $db, { slug => 'kiln_co' } )->dao( $test_db->db )->db;
    my $tseat  = Registry::DAO::Resource->create( $tdb, { name => 'Wheel', kind => 'finite', capacity => 4 } );
    my $toffer = Registry::DAO::Offer->create( $tdb, { name => 'Taster' } );
    my $tv     = $toffer->draft( $tdb, offer_terms( $tseat->id ) )->publish($tdb);
    throws_ok {
        $tdb->query( 'DELETE FROM offer_version_payment_plans WHERE offer_version_id = ?', $tv->id )
    } qr/offer \Q@{[ $toffer->id ]}\E version 1/, "and so is removing one in a new tenant's schema";
};

subtest 'version stores its currency' => sub {
    is drafted( 'Euro night', currency => 'eur' )->currency, 'eur', 'a version round-trips its currency';
    is drafted('Dollar night')->currency, 'usd', 'and is in usd when none is given';
    for my $bad (qw( USD us dollars )) {
        throws_ok { drafted( "Currency $bad", currency => $bad ) }
            qr/offer_versions_currency_check/, "currency '$bad' is refused, Stripe wants a lowercase ISO code";
    }
};

subtest 'plan edit and publish take turns' => sub {
    my $draft = new_offer('Race')->draft( $db, offer_terms( $seat->id ) );
    my $tx = $db->begin;
    $db->query( q{INSERT INTO offer_version_payment_plans (offer_version_id, id, kind) VALUES (?, 'late', 'one_time')},
        $draft->id );

    my $other = Mojo::Pg->new( $test_db->uri )->db;
    $other->query(q{SET lock_timeout = '200ms'});
    throws_ok {
        $other->query( 'UPDATE registry.offer_versions SET published_at = now() WHERE id = ?', $draft->id )
    } qr/lock timeout/, 'a publish waits for a plan change in flight instead of slipping past it';
    undef $tx;
};

done_testing;
