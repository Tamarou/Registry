#!/usr/bin/env perl
# ABOUTME: A session's seats are never oversold through checkout: holds and places together stay within its capacity.
# ABOUTME: A child cannot hold a session they already have a place in, and an ended place frees its seat for the next cart.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( days_from_now );
use Test::Registry::Sessions qw( make_session session_offer cart_at_hold );
use Registry::DAO::Entitlement;
use Registry::DAO::FamilyMember;
use Registry::DAO::WorkflowRun;
use Registry::PriceOps::Hold;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

# A session of two seats, and four families of one child each.
my $session = make_session( $db, days => [ map { days_from_now($_) } 30 .. 32 ], capacity => 2 );
my $price   = session_offer( $db, $session, price_cents => 30000 );
my @families = map {
    my $parent = Test::Registry::Fixtures::create_user( $db, { username => "cap_parent_$_" } );
    { parent => $parent, child => Registry::DAO::FamilyMember->create( $db,
        { family_id => $parent->id, child_name => "Cap Kid $_", birth_date => '2018-01-01' } ) }
} 1 .. 4;

sub cart ($f) { cart_at_hold( $dao, $f->{parent}->id, [ $f->{child}->id, $session->id, $price->id, 'pay' ] ) }
sub hold ( $run, $step ) { $run->process( $db, $step, {} ) }
sub place ($f) {
    Registry::DAO::Entitlement->grant( $db, {
        holder_family_member_id => $f->{child}->id, payer_user_id => $f->{parent}->id,
        offer_version_id => $price->id, payment_plan_id => 'pay',
        starts_at => '2026-01-01T00:00:00Z', resource_id => $session->id, units => 1,
    } );
}

my @carts;
subtest 'holds never exceed capacity' => sub {
    # Three carts reach the hold while the session still has room for each.
    @carts = map { [ cart($_) ] } @families[ 0 .. 2 ];
    ok !hold( $carts[$_]->@* )->{errors}, "cart $_ holds its seat" for 0, 1;
    is $session->free_units($db), 0, 'the session is full';
    like hold( $carts[2]->@* )->{errors}[0], qr/is full|no longer has room/, 'the third is refused';
    is $session->free_units($db), 0, 'and nothing is oversold';
};

# Gives back the seats the first two carts hold.
for my $run ( map { $_->[0] } @carts[ 0, 1 ] ) {
    Registry::PriceOps::Hold->find( $db, { id => $_ }, 'id' )->release($db)
        for values Registry::DAO::WorkflowRun->find( $db, { id => $run->id } )->data->{cart_holds}->%*;
}

my $placed;
subtest 'a child cannot hold a session they already have a place in' => sub {
    is $session->free_units($db), 2, 'both seats free';
    my $f = $families[3];
    my ( $run, $step ) = cart($f);
    # The child is given a place between the cart and the hold.
    $placed = place($f);
    like hold( $run, $step )->{errors}[0], qr/Cap Kid 4 already has a place in/, 'refused';
    is $session->free_units($db), 1, 'and only the place takes a seat';
};

subtest 'an ended place frees its seat' => sub {
    my @waiting = map { [ cart($_) ] } @families[ 0 .. 1 ];
    ok !hold( $waiting[0]->@* )->{errors}, 'the first cart takes the free seat';
    like hold( $waiting[1]->@* )->{errors}[0], qr/is full|no longer has room/, 'the second finds none';
    $placed->end( $db, 'refunded', 'dropped' );
    ok !hold( $waiting[1]->@* )->{errors}, 'once the place ends, the second cart holds its seat';
    is $session->free_units($db), 0, 'and the session is full again';
};

done_testing;
