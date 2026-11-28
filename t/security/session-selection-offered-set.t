#!/usr/bin/env perl
# ABOUTME: A session posted to the session cart must be one the cart offered: on sale, with room, at a price that buys it.
# ABOUTME: An id naming nothing, a started session, a duplicated parameter or another session's price never reach cart_lines.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( days_from_now );
use Test::Registry::Sessions qw( make_session session_offer cart_run add_cart_line );
use Registry::DAO::FamilyMember;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $parent = Test::Registry::Fixtures::create_user( $db, { username => 'offered_parent' } );
my ( $kid, $sib ) = map {
    Registry::DAO::FamilyMember->create( $db, { family_id => $parent->id, child_name => $_, birth_date => '2017-05-01' } )
} 'Kid', 'Sib';

sub on_sale_session (%o) { make_session( $db, days => [ map { days_from_now($_) } 30 .. 32 ], %o ) }

my $offered = on_sale_session();
my $price   = session_offer( $db, $offered, price_cents => 30000 );

# The step's result and the cart's lines after posting $session_id at $choice.
sub post ( $session_id, $choice = $price->id . '/pay' ) {
    my ( $run, $step ) = cart_run( $dao, $parent->id, $kid->id, $sib->id );
    my $result = add_cart_line( $db, $run, $step,
        family_member_id => $kid->id, resource_id => $session_id, choice => $choice );
    return ( $result, $run->data->{cart_lines} );
}

# Positive control: without it every refusal below could pass because the
# fixture never produced a working line in the first place.
subtest 'a session the cart offered is accepted' => sub {
    my ( $result, $lines ) = post( $offered->id );
    ok !$result->{errors}, 'no errors' or diag explain $result->{errors};
    is scalar @{ $lines // [] }, 1, 'the line is in the cart';
};

subtest 'a session id that names nothing is refused' => sub {
    my ( $result, $lines ) = post('ffffffff-ffff-4fff-8fff-ffffffffffff');
    like $result->{errors}[0], qr/Choose one of the listed sessions/, 'refused';
    ok !$lines, 'and nothing reaches the cart';
};

subtest 'an id that is not a uuid is refused, not cast' => sub {
    my ( $result, $lines ) = post('not-a-uuid');
    like $result->{errors}[0], qr/Choose one of the listed sessions/, 'refused';
    ok !$lines, 'and nothing reaches the cart';
};

subtest 'a session that has started is refused' => sub {
    my $started = make_session( $db, days => [ days_from_now(-1), days_from_now(1) ] );
    my $its     = session_offer( $db, $started );
    my ( $result, $lines ) = post( $started->id, $its->id . '/pay' );
    like $result->{errors}[0], qr/Choose one of the listed sessions/, 'refused';
    ok !$lines, 'and nothing reaches the cart';
};

# req->params->to_hash yields an ARRAYREF for a duplicated key.
subtest 'a duplicated resource_id parameter is refused' => sub {
    my $other = on_sale_session();
    my ( $result, $lines ) = post( [ $offered->id, $other->id ] );
    like $result->{errors}[0], qr/Choose one of the listed prices/, 'refused';
    ok !$lines, 'and nothing reaches the cart';
};

# A real, current price that buys a different session.
subtest "another session's price is refused" => sub {
    my $elsewhere = on_sale_session();
    my $its       = session_offer( $db, $elsewhere );
    my ( $result, $lines ) = post( $offered->id, $its->id . '/pay' );
    like $result->{errors}[0], qr/Choose one of the listed prices/, 'refused';
    ok !$lines, 'and nothing reaches the cart';
};

subtest "a full session is refused, counting the cart's own lines" => sub {
    my $one_seat = on_sale_session( capacity => 1 );
    my $its      = session_offer( $db, $one_seat );
    my ( $run, $step ) = cart_run( $dao, $parent->id, $kid->id, $sib->id );
    ok !add_cart_line( $db, $run, $step, family_member_id => $kid->id, resource_id => $one_seat->id,
        choice => $its->id . '/pay' )->{errors}, 'the first child takes the one seat';
    like add_cart_line( $db, $run, $step, family_member_id => $sib->id, resource_id => $one_seat->id,
        choice => $its->id . '/pay' )->{errors}[0], qr/is full/, 'the second is refused';
    is scalar $run->data->{cart_lines}->@*, 1, 'and only the first line is in the cart';
};

done_testing;
