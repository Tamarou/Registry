#!/usr/bin/env perl
# ABOUTME: Holding a session cart's seats re-asks the whole cart at the hold's instant, then holds one seat per line.
# ABOUTME: It writes one owed charge, each child's first charge summed, with every line's share; any refusal releases every hold.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use POSIX qw( strftime );
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( days_from_now );
use Test::Registry::Sessions qw( make_session session_offer cart_run add_cart_line cart_at_hold );
use Test::Registry::Offers qw( instalment_plan );
use Registry::DAO::Entitlement;
use Registry::DAO::FamilyMember;
use Registry::DAO::WorkflowSteps::SessionCart;
use Registry::DAO::WorkflowRun;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $parent   = Test::Registry::Fixtures::create_user( $db, { username => 'hold_parent' } );
my $stranger = Test::Registry::Fixtures::create_user( $db, { username => 'hold_stranger' } );
sub child ( $family, $name ) {
    Registry::DAO::FamilyMember->create( $db, { family_id => $family->id, child_name => $name, birth_date => '2016-01-01' } );
}
my ( $kid, $sib ) = ( child( $parent, 'Kid' ), child( $parent, 'Sib' ) );

sub session ( %o ) { scalar make_session( $db, days => [ map { days_from_now($_) } 30 .. 32 ], %o ) }
my $policies = { refund => { kind => 'none' }, missed_payment => { kind => 'end' } };
sub full_price ($s) { session_offer( $db, $s, price_cents => 30000 ) }
sub in_parts ($s) {
    session_offer( $db, $s, price_cents => 27000, policies => $policies, payment_plans =>
        [ { id => 'pay', kind => 'one_time' }, instalment_plan( id => 'parts', count => 3, cadence => 'weekly' ) ] );
}

# A run past its cart, at its hold step; each line is [ child, session, version, plan ].
sub held_run (@lines) {
    cart_at_hold( $dao, $parent->id, map { [ $_->[0]->id, $_->[1]->id, $_->[2]->id, $_->[3] ] } @lines );
}
sub data_of ($run) { Registry::DAO::WorkflowRun->find( $db, { id => $run->id } )->data }
sub live_holds ($run) {
    $db->query( q{SELECT count(*) FROM holds WHERE workflow_run_id = ? AND state = 'held' AND expires_at > clock_timestamp()},
        $run->id )->array->[0];
}

subtest 'the owed charge is the one-time price plus the first instalment' => sub {
    my $s = session();
    my ( $run, $hold ) = held_run( [ $kid, $s, full_price($s), 'pay' ], [ $sib, $s, in_parts($s), 'parts' ] );
    my $result = $run->process( $db, $hold, {} );
    ok !$result->{errors}, 'held' or diag explain $result;
    my $owed = data_of($run)->{owed_payment};
    is $owed->{purpose}, 'session_checkout', 'for the session checkout';
    is $owed->{amount_cents}, 30000 + 9000, 'one-time child plus first of three instalments of $270';
    is_deeply [ map { $_->{share_cents} } $owed->{lines}->@* ], [ 30000, 9000 ], 'each line carries its share';
    is_deeply [ map { $_->{kind} } $owed->{lines}->@* ], [qw( one_time instalments )], 'and its plan kind';
    is $owed->{lines}[0]{parts}, undef, 'a one-time line has no parts';
    is_deeply [ map { $_->{amount_cents} } $owed->{lines}[1]{parts}->@* ], [ 9000, 9000, 9000 ],
        'an instalment line carries every part';
    my $holds = data_of($run)->{cart_holds};
    is_deeply [ map { $_->{hold_id} } $owed->{lines}->@* ],
        [ map { $holds->{ join ':', $_->id, $s->id } } $kid, $sib ], "each line names its child's hold";
};

subtest 'each line holds one seat' => sub {
    my $s   = session();
    my $cap = $s->free_units($db);
    my ( $run, $hold ) = held_run( [ $kid, $s, full_price($s), 'pay' ], [ $sib, $s, in_parts($s), 'parts' ] );
    ok !$run->process( $db, $hold, {} )->{errors}, 'held';
    is $s->free_units($db), $cap - 2, 'two seats held';
    is live_holds($run), 2, 'one hold per line';
    my $minutes = $db->query( q{SELECT DISTINCT round(extract(epoch FROM expires_at - placed_at) / 60)
                                  FROM holds WHERE workflow_run_id = ?}, $run->id )->arrays->flatten->to_array;
    is_deeply $minutes, [15], 'each for fifteen minutes';
};

subtest 'a resubmit keeps live holds' => sub {
    # Two seats, both the cart's: its own holds count as room when asked again.
    my $s   = session( capacity => 2 );
    my $cap = $s->free_units($db);
    my ( $run, $hold ) = held_run( [ $kid, $s, full_price($s), 'pay' ], [ $sib, $s, in_parts($s), 'parts' ] );
    ok !$run->process( $db, $hold, {} )->{errors}, 'held';
    my $first = data_of($run)->{cart_holds};
    ok !$run->process( $db, $hold, {} )->{errors}, 'held again';
    is_deeply data_of($run)->{cart_holds}, $first, 'the same holds';
    is $s->free_units($db), $cap - 2, 'and no more seats';
};

subtest 'a price granting more than one seat per child is not offered' => sub {
    my $s    = session();
    my $pair = session_offer( $db, $s, units_per_acceptance => 2, per_booking_cap => 1 );
    my ( $run, $cart ) = cart_run( $dao, $parent->id, $kid->id );
    is add_cart_line( $db, $run, $cart, family_member_id => $kid->id, resource_id => $s->id,
        choice => $pair->id . '/pay' )->{errors}[0], 'Choose one of the listed prices', 'refused';
};

subtest 'a cart being paid for keeps its holds' => sub {
    my $s = session();
    my ( $run, $hold ) = held_run( [ $kid, $s, full_price($s), 'pay' ] );
    ok !$run->process( $db, $hold, {} )->{errors}, 'held';
    $run->update_data( $db, { owed_payment_id => '00000000-0000-0000-0000-000000000001' } );
    like $run->process( $db, $hold, {} )->{errors}[0], qr/already being paid for/, 'refused';
    is live_holds($run), 1, 'the hold stays';
};

subtest 'an early bird crossed before the hold is refused and every hold released' => sub {
    my $s   = session();
    my $cap = $s->free_units($db);
    # A deadline fifteen seconds off, room for a slow setup: chosen before it, held again after it.
    my $deadline = strftime '%Y-%m-%dT%H:%M:%SZ', gmtime( time + 15 );
    my $early    = session_offer( $db, $s, price_cents => 25000, conditions => [ { kind => 'before', at => $deadline } ] );
    my ( $run, $hold ) = held_run( [ $kid, $s, $early, 'pay' ], [ $sib, $s, full_price($s), 'pay' ] );
    ok !$run->process( $db, $hold, {} )->{errors}, 'held before the deadline';
    is $s->free_units($db), $cap - 2, 'two seats held';
    sleep 1 until $db->query( 'SELECT clock_timestamp() > ?::timestamptz', $deadline )->array->[0];
    like $run->process( $db, $hold, {} )->{errors}[0], qr/early-bird.*ended|no longer offered/i, 'refused, with a sentence';
    is $s->free_units($db), $cap, 'every hold released';
    is live_holds($run), 0, 'the run holds nothing';
    ok !data_of($run)->{owed_payment}, 'and owes nothing';
};

subtest 'a session filled meanwhile is refused' => sub {
    my $s     = session( capacity => 2 );
    my $price = full_price($s);
    my ( $run, $hold ) = held_run( [ $kid, $s, $price, 'pay' ], [ $sib, $s, $price, 'pay' ] );
    # Another family takes a seat between the cart and the hold.
    my $other = child( $stranger, 'Other' );
    Registry::DAO::Entitlement->grant( $db, {
        holder_family_member_id => $other->id, payer_user_id => $stranger->id,
        offer_version_id => $price->id, payment_plan_id => 'pay',
        starts_at => '2026-01-01T00:00:00Z', resource_id => $s->id, units => 1,
    } );
    like $run->process( $db, $hold, {} )->{errors}[0], qr/no longer has room/, 'refused';
    is live_holds($run), 0, 'nothing held';
    is $s->free_units($db), 1, 'the free seat stays free';
};

subtest 'a child held in another checkout is refused' => sub {
    # Two tabs: the same child, the same session, two runs.
    my $s     = session();
    my $cap   = $s->free_units($db);
    my $price = full_price($s);
    my ( $first, $first_hold )   = held_run( [ $kid, $s, $price, 'pay' ] );
    my ( $second, $second_hold ) = held_run( [ $kid, $s, $price, 'pay' ] );
    ok !$first->process( $db, $first_hold, {} )->{errors}, 'the first holds';
    is $second->process( $db, $second_hold, {} )->{errors}[0],
        sprintf( '%s is already being booked into %s in another checkout', $kid->child_name, $s->name ), 'the second is refused';
    is $s->free_units($db), $cap - 1, 'only one seat is held';
    is live_holds($second), 0, 'the second run holds nothing';
};

subtest "only the run's own holds count as its room" => sub {
    my $s     = session( capacity => 1 );
    my $price = full_price($s);
    my ( $holder, $step ) = held_run( [ $kid, $s, $price, 'pay' ] );
    ok !$holder->process( $db, $step, {} )->{errors}, 'another run holds the one seat';
    my $elsewhere = session();
    my ($other)   = held_run( [ $sib, $elsewhere, full_price($elsewhere), 'pay' ] );
    # A cart_holds naming the first run's hold is not room for the other run.
    my $data = { user_id => $parent->id, cart_holds => data_of($holder)->{cart_holds} };
    my $line = { family_member_id => $sib->id, resource_id => $s->id, offer_version_id => $price->id, payment_plan_id => 'pay' };
    like Registry::DAO::WorkflowSteps::SessionCart->refusal( $db, $data, [$line], $other->id ), qr/is full/, 'refused';
};

done_testing;
