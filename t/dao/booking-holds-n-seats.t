#!/usr/bin/env perl
# ABOUTME: An in-studio occurrence's capacity counts seats held (count x seats per unit), not family members.
# ABOUTME: A booking's count is checked against its offer's per-booking cap, then by the resource's one locked check.
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
use Registry::DAO::Entitlement;
use Registry::DAO::Tenant;
use Registry::PriceOps::Hold;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $SLUG = 'seat_studio';
Registry::DAO::Tenant->create( $db, { name => 'Seat Studio', slug => $SLUG } );
$db->query( 'SELECT clone_schema(dest_schema => ?)', $SLUG );
my $studio = Registry::DAO->new( url => $dao->url, schema => $SLUG )->db;

my $made = 0;

sub person () {
    return $studio->insert( 'users', { username => 'p-' . ++$made }, { returning => 'id' } )->hash->{id};
}

sub run_id () {
    my $workflow = $studio->insert( 'workflows', { slug => 'book-' . ++$made, name => "Book $made" },
        { returning => 'id' } )->hash->{id};
    return $studio->insert( 'workflow_runs', { workflow_id => $workflow }, { returning => 'id' } )
        ->hash->{id};
}

# A class with $count occurrences of 10 seats and a published class offer
# version covering them, with %terms over offer_terms' defaults.
sub occurrences ( $count, %terms ) {
    my $class = $studio->insert( 'projects', { name => 'Class ' . ++$made, slug => "class-$made" },
        { returning => 'id' } )->hash->{id};
    my $room = $studio->insert( 'locations', { name => 'Room ' . ++$made, slug => "room-$made",
            time_zone => 'America/New_York' },
        { returning => 'id' } )->hash->{id};
    my @resources = map {
        my $event = $studio->insert( 'events', {
            project_id => $class, location_id => $room, teacher_id => person(),
            time       => "2099-03-0${_}T10:00:00Z", duration => 90, capacity => 10,
        }, { returning => 'id' } )->hash->{id};
        Registry::DAO::Resource->for_occurrence( $studio, $event );
    } 1 .. $count;
    my $version = Registry::DAO::Offer->create( $studio, { name => 'Wheel class ' . $made } )
        ->draft( $studio, offer_terms( undef, class_project_id => $class, per_booking_cap => 10, %terms ) )
        ->publish($studio);
    return ( $version, @resources );
}

# The in-studio booking path's capacity call: $count of $version's units in
# $resource, held for a fresh run.
sub book ( $handle, $version, $resource, $count, $lifetime = '15 minutes' ) {
    return Registry::PriceOps::Hold->place( $handle, {
        resource_id     => $resource->id,
        units           => $version->seats_for($count),
        workflow_run_id => run_id(),
        expires_at      => \"clock_timestamp() + interval '$lifetime'",
    } );
}

# A booking already paid for: an entitlement holding $count units' seats.
sub booked ( $version, $resource, $count ) {
    return Registry::DAO::Entitlement->grant( $studio, {
        holder_user_id   => person(),
        offer_version_id => $version->id,
        payment_plan_id  => 'pay',
        starts_at        => '2020-01-01T00:00:00Z',
        resource_id      => $resource->id,
        units            => $version->seats_for($count),
    } );
}

sub holds_on ($resource) {
    return $studio->select( 'holds', 'count(*)', { resource_id => $resource->id } )->array->[0];
}

subtest 'seats held leave the rest' => sub {
    my ( $version, $seats ) = occurrences(1);
    booked( $version, $seats, 3 );
    is $seats->free_units($studio), 7, 'one booking of 3 seats leaves 7';
    throws_ok { book( $studio, $version, $seats, 8 ) } qr/7 of 10 units free: 8 asked for/, '8 more refused';
    ok book( $studio, $version, $seats, 7 ), '7 more granted';
    is $seats->free_units($studio), 0, 'and the occurrence is full';
};

subtest 'an offer of 2 seats per unit booked twice takes 4' => sub {
    my ( $version, $seats ) = occurrences( 1, units_per_acceptance => 2 );
    is book( $studio, $version, $seats, 2 )->units, 4, 'the hold is for 4 seats';
    is $seats->free_units($studio), 6, 'leaving 6';
};

subtest 'a booking above the per-booking cap is refused' => sub {
    my ( $version, $seats ) = occurrences( 1, per_booking_cap => 3 );
    ok book( $studio, $version, $seats, 3 ), 'the cap itself is allowed';
    throws_ok { book( $studio, $version, $seats, 4 ) } qr/at most 3/, 'one more than the cap is refused';
    is $seats->free_units($studio), 7, 'and holds nothing';
};

# A second connection to the studio, giving up on a lock after a moment
# rather than waiting.
sub impatient () {
    my $other = Registry::DAO->new( url => $test_db->uri, schema => $SLUG )->db;
    $other->query(q{SET lock_timeout = '500ms'});
    return $other;
}

subtest 'concurrent requests for the last seats cannot both succeed' => sub {
    my ( $version, $seats ) = occurrences(1);
    booked( $version, $seats, 8 );
    my ( $first, $second ) = ( impatient(), impatient() );
    my $tx = $first->begin;
    ok book( $first, $version, $seats, 2 ), 'the first takes the last 2 seats, uncommitted';
    throws_ok { book( $second, $version, $seats, 2 ) } qr/lock timeout/,
        'the second waits on the occurrence lock rather than reading 2 free';
    $tx->commit;
    throws_ok { book( $second, $version, $seats, 2 ) } qr/0 of 10 units free/,
        'once the first commits, the second is refused';
    is holds_on($seats), 1, 'one hold stands';
};

subtest 'zero negative or fractional units refused' => sub {
    my ( $version, $seats ) = occurrences( 1, units_per_acceptance => 2 );
    for my $count ( 0, -1, '1.5', '0.5', '', 'two', undef ) {
        throws_ok { book( $studio, $version, $seats, $count ) } qr/whole number of at least one/,
            sprintf 'a count of %s is refused', $count // 'nothing';
    }
    is holds_on($seats), 0, 'and nothing is held';
};

subtest 'expired holds do not count' => sub {
    my ( $version, $seats ) = occurrences(1);
    my $hold = book( $studio, $version, $seats, 5 );
    $studio->update( 'holds', { expires_at => \"clock_timestamp() - interval '1 second'" }, { id => $hold->id } );
    is $seats->free_units($studio), 10, 'an expired hold for 5 leaves all 10 free';
    ok book( $studio, $version, $seats, 10 ), 'and all 10 can be booked';
};

subtest 'ended entitlement frees seats partial refund does not' => sub {
    my ( $version, $seats ) = occurrences(1);
    my ( $refunded, $partly ) = ( booked( $version, $seats, 4 ), booked( $version, $seats, 3 ) );
    $refunded->end( $studio, 'refunded', 're_full' );
    $partly->record_refund( $studio, { amount_cents => 500, stripe_refund_id => 're_part' } );
    is $seats->free_units($studio), 7, 'the ended booking freed its 4; the partly refunded one holds its 3';
    throws_ok { book( $studio, $version, $seats, 8 ) } qr/7 of 10 units free/, '8 refused';
    ok book( $studio, $version, $seats, 7 ), '7 granted';
};

subtest 'other occurrence seats not counted' => sub {
    my ( $version, $mine, $other ) = occurrences(2);
    booked( $version, $other, 4 );
    book( $studio, $version, $other, 6 );
    is $mine->free_units($studio), 10, "the other occurrence's booking and hold leave this one's 10";
    ok book( $studio, $version, $mine, 10 ), 'all 10 can be booked';
};

subtest 'huge unit count refused without overflow' => sub {
    my ( $version, $seats ) = occurrences(1);
    booked( $version, $seats, 10 );
    throws_ok { book( $studio, $version, $seats, 1 ) } qr/0 of 10 units free: 1 asked for/,
        'at exactly full, 1 is refused';

    my ( $open, $empty ) = occurrences( 1, per_booking_cap => 2**31 - 1, units_per_acceptance => 2**31 - 1 );
    throws_ok { book( $studio, $open, $empty, 2**31 - 1 ) } qr/10 of 10 units free: 4611686014132420609 asked for/,
        'the largest count of the largest offer is refused in exact seats';
    throws_ok { book( $studio, $open, $empty, '4611686018427387904' ) } qr/at most 2147483647/,
        '2**62 units are refused by the cap';
    throws_ok {
        Registry::PriceOps::Hold->place( $studio, {
            resource_id => $empty->id, units => '4611686018427387904', workflow_run_id => run_id(),
            expires_at  => \"clock_timestamp() + interval '1 minute'",
        } )
    } qr/10 of 10 units free: 4611686018427387904 asked for/, '2**62 seats are refused by the capacity check';
    is holds_on($empty), 0, 'and nothing is held';
};

subtest 'refused request leaves no hold' => sub {
    my ( $version, $seats ) = occurrences( 1, per_booking_cap => 20 );
    booked( $version, $seats, 9 );
    throws_ok { book( $studio, $version, $seats, 2 ) } qr/1 of 10 units free/, 'a request for 2 is refused';
    throws_ok { book( $studio, $version, $seats, 21 ) } qr/at most 20/, 'as is one above the cap';
    is holds_on($seats), 0, 'leaving no hold';
    ok book( impatient(), $version, $seats, 1 ), 'and the next request takes the lock without waiting';
};

done_testing;
