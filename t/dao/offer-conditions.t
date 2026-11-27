#!/usr/bin/env perl
# ABOUTME: Sibling and early-bird conditions on offer versions, and the versions a child may choose.
# ABOUTME: Sibling, early-bird and regular prices are separate published versions, against real Postgres.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Offers qw( offer_terms );
use Test::Registry::Sessions qw( make_session session_offer );
use Registry::DAO::Offer;
use Registry::DAO::Resource;
use Registry::DAO::Entitlement;
use Registry::DAO::FamilyMember;
use Registry::DAO::OfferVersion;

my $test_db = Test::Registry::DB->new;
my $db      = $test_db->db->db;

my $AT    = '2027-02-01T00:00:00Z';
my $EARLY = '2027-03-01T00:00:00Z';

my $made = 0;

# A parent and two children in its family: ($parent_id, $kid1_id, $kid2_id).
sub family () {
    my $parent = Test::Registry::Fixtures::create_user( $db, { username => 'oc-parent-' . ++$made } )->id;
    return ( $parent, map {
        Registry::DAO::FamilyMember->create( $db,
            { family_id => $parent, child_name => "Kid $_ of $made", birth_date => '2018-05-01' } )->id
    } 1, 2 );
}

# An active entitlement to $version held by child $kid, paid for by $parent,
# in effect from $starts_at.
sub hold ( $version, $kid, $parent, $starts_at = '2026-09-01T00:00:00Z' ) {
    return Registry::DAO::Entitlement->create( $db, {
        holder_family_member_id => $kid,
        payer_user_id           => $parent,
        offer_version_id        => $version->id,
        payment_plan_id         => 'pay',
        starts_at               => $starts_at,
    } );
}

# A session sold at regular $300, sibling $270 and early-bird $250.
sub priced_session () {
    my $s = make_session($db);
    my ( $regular, $sibling, $early ) = map { session_offer( $db, $s, %$_ ) }
        { price_cents => 30000 },
        { price_cents => 27000, conditions => [ { kind => 'family_holds_entitlement' } ] },
        { price_cents => 25000, conditions => [ { kind => 'before', at => $EARLY } ] };
    return ( $s, $regular, $sibling, $early );
}

# The ids of the versions of $s a child may choose under %ctx, in order.
sub choosable ( $s, %ctx ) {
    return [ map { $_->{version}->id } grep { !$_->{unmet}->@* }
            Registry::DAO::OfferVersion->choosable_for( $db, $s->id, { at => $AT, %ctx } )->@* ];
}

# Another offer's version, on another session.
sub other_version () { session_offer( $db, scalar make_session($db) ) }

subtest 'the first child chooses early bird or regular' => sub {
    my ( $s, $regular, $sibling, $early ) = priced_session();
    my ( $parent, $kid1 ) = family();
    is_deeply choosable( $s, holder_family_member_id => $kid1 ), [ $early->id, $regular->id ],
        'early bird then regular, cheapest first';

    my @all = Registry::DAO::OfferVersion->choosable_for( $db, $s->id,
        { at => $AT, holder_family_member_id => $kid1 } )->@*;
    is_deeply [ map { $_->{version}->id } @all ], [ $early->id, $sibling->id, $regular->id ],
        'every current version is listed, by price';
    is scalar $all[1]{unmet}->@*, 1, 'the sibling rate says why it is not choosable';
    like $all[1]{unmet}[0], qr/\w/, 'in a sentence';
};

subtest 'a sibling earlier in the cart qualifies' => sub {
    my ( $s, $regular, $sibling, $early ) = priced_session();
    my ( $parent, $kid1, $kid2 ) = family();
    is_deeply choosable( $s, holder_family_member_id => $kid2, cart_lines => [ { family_member_id => $kid1, offer_id => $regular->offer_id } ] ),
        [ $early->id, $sibling->id, $regular->id ], 'kid 2 may choose the sibling rate too';
};

subtest 'a sibling bought earlier qualifies' => sub {
    my ( $s, $regular, $sibling ) = priced_session();
    my ( $parent, $kid1, $kid2 ) = family();
    hold( other_version(), $kid1, $parent );
    is_deeply $sibling->unmet_conditions( $db, { holder_family_member_id => $kid2, at => $AT } ), [],
        'kid 2 meets the sibling condition';
};

subtest 'a sibling bought for a later session qualifies' => sub {
    my ( $s, $regular, $sibling ) = priced_session();
    my ( $parent, $kid1, $kid2 ) = family();
    hold( other_version(), $kid1, $parent, '2027-03-01T00:00:00Z' );
    is_deeply $sibling->unmet_conditions( $db, { holder_family_member_id => $kid2, at => $AT } ), [],
        "kid 2 meets the sibling condition before kid 1's session starts";
};

subtest 'a child does not qualify itself through its own earlier cart line' => sub {
    my ( $s, $regular, $sibling, $early ) = priced_session();
    my ( $parent, $kid1, $kid2 ) = family();
    my $lines = [ { family_member_id => $kid1, offer_id => $regular->offer_id } ];
    is_deeply choosable( $s, holder_family_member_id => $kid1, cart_lines => $lines ),
        [ $early->id, $regular->id ], "kid 1's own line does not give kid 1 the sibling rate";
    is_deeply choosable( $s, holder_family_member_id => $kid2, cart_lines => $lines ),
        [ $early->id, $sibling->id, $regular->id ], 'the same line gives it to kid 2';
};

subtest 'a past due sibling entitlement still qualifies' => sub {
    my ( $s, $regular, $sibling ) = priced_session();
    my ( $parent, $kid1, $kid2 ) = family();
    hold( other_version(), $kid1, $parent )->mark_past_due( $db, 'in_oc_past_due' );
    is_deeply $sibling->unmet_conditions( $db, { holder_family_member_id => $kid2, at => $AT } ), [],
        'kid 2 still meets the sibling condition';
};

subtest 'offer_ids limits which offers count' => sub {
    my $s     = make_session($db);
    my $club  = other_version();
    my $other = other_version();
    my $sibling = session_offer( $db, $s, price_cents => 27000,
        conditions => [ { kind => 'family_holds_entitlement', offer_ids => [ $club->offer_id ] } ] );
    my ( $parent, $kid1, $kid2 ) = family();
    my $unmet = sub (%ctx) {
        $sibling->unmet_conditions( $db, { holder_family_member_id => $kid2, at => $AT, %ctx } );
    };

    hold( $other, $kid1, $parent );
    is scalar $unmet->()->@*, 1, 'a sibling holding another offer does not count';
    is scalar $unmet->( cart_lines => [ { family_member_id => $kid1, offer_id => $other->offer_id } ] )->@*, 1, 'nor does a cart line for another offer';
    is_deeply $unmet->( cart_lines => [ { family_member_id => $kid1, offer_id => $club->offer_id } ] ), [], 'a cart line for a listed offer does';
    hold( $club, $kid1, $parent );
    is_deeply $unmet->(), [], 'and so does a sibling holding a listed offer';
};

subtest 'before is exclusive' => sub {
    my ( $s, $regular, $sibling, $early ) = priced_session();
    my ( $parent, $kid1 ) = family();
    is_deeply choosable( $s, holder_family_member_id => $kid1, at => $EARLY ), [ $regular->id ],
        'at the deadline itself only the regular rate is left';
    is_deeply choosable( $s, holder_family_member_id => $kid1, at => '2027-02-28T19:00:00-05:00' ),
        [ $regular->id ], 'the same instant in another offset is past it too';
    is_deeply choosable( $s, holder_family_member_id => $kid1, at => '2027-02-28T18:59:59-05:00' ),
        [ $early->id, $regular->id ], 'a second before it is not';
};

subtest 'the holder itself does not qualify' => sub {
    my ( $s, $regular, $sibling ) = priced_session();
    my ( $parent, $kid1 ) = family();
    hold( other_version(), $kid1, $parent );
    is scalar $sibling->unmet_conditions( $db, { holder_family_member_id => $kid1, at => $AT } )->@*, 1,
        "kid 1's own entitlement does not give kid 1 the sibling rate";
};

subtest 'an ended sibling entitlement does not qualify' => sub {
    my ( $s, $regular, $sibling ) = priced_session();
    my ( $parent, $kid1, $kid2 ) = family();
    hold( other_version(), $kid1, $parent )->end( $db, 'refunded', 're_oc_ended', '2027-01-15T00:00:00Z' );
    is scalar $sibling->unmet_conditions( $db, { holder_family_member_id => $kid2, at => $AT } )->@*, 1,
        'kid 2 no longer meets the sibling condition';
};

subtest 'holder_is_offerer is never met here' => sub {
    my $s       = make_session($db);
    my $version = session_offer( $db, $s, conditions => [ { kind => 'holder_is_offerer' } ] );
    my ( $parent, $kid1, $kid2 ) = family();
    hold( other_version(), $kid1, $parent );
    is scalar $version->unmet_conditions( $db,
        { holder_family_member_id => $kid2, at => $AT, cart_lines => [ { family_member_id => $kid1, offer_id => $version->offer_id } ] } )->@*, 1,
        'it is unmet at checkout';
    is_deeply choosable( $s, holder_family_member_id => $kid2 ), [], 'so nothing on the session is choosable';
};

subtest 'a version buying the resource as one of its set is listed' => sub {
    my $s   = make_session($db);
    my $set = session_offer( $db, $s, resource_id => undef,
        resource_ids => [ $s->id, scalar( make_session($db) )->id ] );
    my ( $parent, $kid1 ) = family();
    is_deeply choosable( $s, holder_family_member_id => $kid1 ), [ $set->id ], 'its set names the session';
};

subtest "a class version covering the resource's occurrence is listed" => sub {
    my $n     = ++$made;
    my $class = Test::Registry::Fixtures::create_project( $db, { name => "Cond class $n", slug => "cond-class-$n" } );
    my $event = Test::Registry::Fixtures::create_event( $db, {
        project_id  => $class->id,
        location_id => Test::Registry::Fixtures::create_location( $db,
            { name => "Cond room $n", slug => "cond-room-$n" } )->id,
        teacher_id => Test::Registry::Fixtures::create_user( $db, { username => "cond-teacher-$n" } )->id,
        time       => '2027-06-07T13:00:00Z', duration => 90, capacity => 10,
    } );
    my $occurrence = Registry::DAO::Resource->for_occurrence( $db, $event->id );
    my $version    = Registry::DAO::Offer->create( $db, { name => "Cond class offer $n" } )
        ->draft( $db, offer_terms( undef, class_project_id => $class->id ) )->publish($db);
    my ( $parent, $kid1 ) = family();
    is_deeply choosable( $occurrence, holder_family_member_id => $kid1 ), [ $version->id ],
        'its class holds the occurrence';
};

subtest 'an unknown condition kind is refused by name' => sub {
    my ( $s, $regular ) = priced_session();
    # A kind this code cannot evaluate, as a stored row could carry; never read as met or unmet.
    my $odd = Registry::DAO::OfferVersion->new(
        ( map { $_ => $regular->$_ } qw( id offer_id version resource_id price_cents currency
            units_per_acceptance per_booking_cap policies published_at created_at ) ),
        conditions => [ { kind => 'moon_phase' } ] );
    throws_ok { $odd->unmet_conditions( $db, { at => $AT } ) } qr/unknown condition kind 'moon_phase'/,
        'the refusal names the kind';
};

subtest 'an at with no offset is refused' => sub {
    my ( $s, $regular, $sibling ) = priced_session();
    throws_ok { $sibling->unmet_conditions( $db, { at => '2027-02-01T00:00:00' } ) } qr/instant with its offset/,
        'a local time is not an instant';
    throws_ok { Registry::DAO::OfferVersion->choosable_for( $db, $s->id, { at => '2027-02-01' } ) }
        qr/instant with its offset/, 'nor is a date';
};

done_testing;
