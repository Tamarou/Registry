#!/usr/bin/env perl
# ABOUTME: A session is one finite resource whose days are its events, timed in its location's zone.
# ABOUTME: Its window, sale, expiry and refund cutoff read those days, against real Postgres.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Offers qw( offer_terms );
use Test::Registry::Sessions qw( make_session );
use Registry::DAO;
use Registry::DAO::Entitlement;
use Registry::DAO::Offer;
use Registry::DAO::Payment;
use Registry::DAO::Resource;
use Registry::DAO::WorkflowSteps::ApplyRefundPolicy;

my $test_db = Test::Registry::DB->new;
my $db      = $test_db->db->db;

my $made = 0;
sub person () { Test::Registry::Fixtures::create_user( $db, { username => 'sr-p-' . ++$made } )->id }

# Whether instants $got and $want are the same instant.
sub same_instant ( $got, $want ) {
    $db->query( 'SELECT ?::timestamptz = ?::timestamptz', $got, $want )->array->[0];
}

# Local wall-clock time $at in zone $tz, as an instant.
sub local_instant ( $at, $tz ) {
    $db->query( 'SELECT ?::timestamp AT TIME ZONE ?', $at, $tz )->array->[0];
}

# A published version of a new offer selling $session under $policies.
sub version ( $session, $policies ) {
    return Registry::DAO::Offer->create( $db, { name => 'Camp ' . ++$made } )
        ->draft( $db, offer_terms( $session->id, policies => $policies ) )->publish($db);
}

# One seat of $session under $version, optionally paid by $payment for $share cents.
sub booking ( $version, $session, $payment = undef, $share = undef ) {
    return Registry::DAO::Entitlement->grant( $db, {
        holder_user_id   => person(),
        offer_version_id => $version->id,
        payment_plan_id  => 'pay',
        starts_at        => '2020-01-01T00:00:00Z',
        resource_id      => $session->id,
        units            => 1,
        $payment ? ( payment_id => $payment->id, payment_share_cents => $share ) : (),
    } );
}

subtest 'a session has its days in time order' => sub {
    # Given out of order: the days come back in time order.
    my $s = make_session( $db, days => [qw( 2027-06-09 2027-06-07 2027-06-08 )], capacity => 12 );
    is $s->kind,     'finite', 'it is one finite resource';
    is $s->capacity, 12,       'with the session capacity';
    is_deeply $s->waitlist, { kind => 'none' }, 'and no waitlist';
    ok $s->is_session($db), 'it is a session';

    my $days = $s->session_days($db);
    is scalar @$days, 3, 'it has three days';
    ok same_instant( $days->[$_]{time}, local_instant( "2027-06-0${\( 7 + $_ )} 09:00", 'America/New_York' ) ),
        "day $_ starts at 09:00 local"
        for 0 .. 2;
    is_deeply [ map { $_->{duration} } @$days ], [ 420, 420, 420 ], 'each runs 420 minutes';
    ok !Registry::DAO::Resource->create( $db, { name => 'Wheel', kind => 'finite', capacity => 1 } )->is_session($db),
        'a resource with no days is not a session';
    ok !eval { Registry::DAO::Resource->for_occurrence( $db, $days->[0]{id} ) }, 'a day is no occurrence of its own';
    like $@, qr/session's day/, 'the schema says why';
};

subtest 'occurrence window runs from first start to last end' => sub {
    my $tz = 'America/Denver';
    my $s  = make_session( $db, time_zone => $tz, days => [qw( 2027-06-07 2027-06-08 2027-06-09 )],
        start => '09:00', minutes => 420, capacity => 12 );
    my ( $from, $to ) = $s->occurrence_window($db);
    ok same_instant( $from, local_instant( '2027-06-07 09:00', $tz ) ), 'from the first day 09:00 in Denver';
    ok same_instant( $to,   local_instant( '2027-06-09 16:00', $tz ) ), 'to the last day 16:00 in Denver';
};

subtest 'an unstarted published session is on sale' => sub {
    ok make_session($db)->on_sale($db), 'published, its first day still ahead: on sale';
};

subtest 'a session entitlement expires at its last day end' => sub {
    my $over   = make_session( $db, days => [qw( 2026-01-05 2026-01-06 2026-01-07 )] );
    my $ahead  = make_session($db);
    my $expiry = { refund => { kind => 'none' }, expiry => { kind => 'end_of_occurrence' } };
    my $ended  = booking( version( $over, $expiry ), $over );
    my $kept   = booking( version( $ahead, $expiry ), $ahead );

    is_deeply Registry::DAO::Entitlement->expire_ended_occurrences($db), [ $ended->id ],
        'exactly the ended session\'s entitlement expires';
    my $now = Registry::DAO::Entitlement->find( $db, { id => $ended->id } );
    is $now->state, 'expired', 'it is expired';
    ok same_instant( $now->ended_at, local_instant( '2026-01-07 16:00', 'America/New_York' ) ),
        'at its last day\'s end';
    is Registry::DAO::Entitlement->find( $db, { id => $kept->id } )->state, 'active',
        'the session still ahead stays active';
};

done_testing;
