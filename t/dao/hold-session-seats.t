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

done_testing;
