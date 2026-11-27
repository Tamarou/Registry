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

subtest 'started sessions are not on sale' => sub {
    my ($yesterday) = $db->query(q{SELECT ((now() AT TIME ZONE 'America/New_York')::date - 1)::text})->array->@*;
    ok !make_session( $db, days => [$yesterday] )->on_sale($db), 'its first day was yesterday: not on sale';
};

subtest 'a queue waitlist without offer hours is refused' => sub {
    my $made = eval { make_session( $db, waitlist => { kind => 'queue' } ) };
    like $@, qr/waitlist/, 'a queue with no offer_hold_hours is refused';
    ok !$made, 'and no session is made';
    is_deeply make_session( $db, waitlist => { kind => 'queue', offer_hold_hours => 24 } )->waitlist,
        { kind => 'queue', offer_hold_hours => 24 }, 'with whole hours it is kept';
};

subtest 'refund cutoff counts back from the first day' => sub {
    my $s       = make_session($db);
    my $version = version( $s, { refund => { kind => 'full_until_cutoff', cutoff_hours => 24 } } );
    my $paid    = Registry::DAO::Payment->create( $db, {
        user_id => person(), amount_cents => 5000, status => 'completed',
        stripe_payment_intent_id => 'pi_sr_' . ++$made, metadata => {} } );
    my $e     = booking( $version, $s, $paid, 5000 );
    my $first = ( $s->occurrence_window($db) )[0];
    my $before = sub ($hours) {
        $db->query( 'SELECT ?::timestamptz - make_interval(hours => ?)', $first, $hours )->array->[0];
    };
    my $refusal = sub ($at) { Registry::DAO::WorkflowSteps::ApplyRefundPolicy->refusal( $db, $e, $at ) };

    is $refusal->( $before->(25) ), undef, '25 hours before the first day it is refunded';
    like $refusal->( $before->(23) ), qr/only until/, '23 hours before the first day it is refused';
    like $refusal->( $before->(23) ), qr/24 hours before it starts/, 'in words that fit a session';
};

subtest 'an occurrence day cannot join a session' => sub {
    my $s   = make_session($db);
    my $day = $s->session_days($db)->[0];
    # An ordinary occurrence with its own resource, at another hour of the same program and room.
    my $event = $db->query( q{
        INSERT INTO events (project_id, location_id, teacher_id, time, duration, capacity, status)
        SELECT project_id, location_id, teacher_id, time + interval '1 hour', 60, 4, 'published' FROM events WHERE id = ?
        RETURNING id
    }, $day->{id} )->array->[0];
    Registry::DAO::Resource->for_occurrence( $db, $event );

    ok !eval { $db->query( 'UPDATE events SET session_resource_id = ? WHERE id = ?', $s->id, $event ); 1 },
        'an event with an occurrence resource cannot become a session day';
    is $db->dbh->state, '23514', 'refused as a check violation';
    like $@, qr/session's day/, 'saying why';
};

subtest 'a session has at least one day' => sub {
    my $before = $db->query('SELECT count(*) FROM resources')->array->[0];
    ok !eval { make_session( $db, days => [] ); 1 }, 'a session of no days is refused';
    like $@, qr/at least one day/, 'saying why';
    is $db->query('SELECT count(*) FROM resources')->array->[0], $before, 'and no resource is made';
};

subtest 'a start in the spring gap is reported shifted' => sub {
    my ( $s, $shifted ) = make_session( $db, days => [qw( 2027-03-14 2027-03-15 )], start => '02:30', minutes => 60 );
    is_deeply $shifted, [ { asked => '2027-03-14 02:30', local_start => '2027-03-14 03:30' } ],
        'the day whose 02:30 does not exist is reported at 03:30';
    ok same_instant( $s->session_days($db)->[0]{time}, local_instant( '2027-03-14 03:30', 'America/New_York' ) ),
        'and starts then';
};

subtest 'waitlist offer hours are capped' => sub {
    ok !eval { make_session( $db, waitlist => { kind => 'queue', offer_hold_hours => 100000 } ); 1 },
        'a hundred thousand hours is refused';
    like $@, qr/waitlist/, 'by the waitlist check';
    is make_session( $db, waitlist => { kind => 'queue', offer_hold_hours => 9999 } )->waitlist->{offer_hold_hours},
        9999, 'four digits are kept';
};

done_testing;
