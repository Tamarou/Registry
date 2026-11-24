#!/usr/bin/env perl
# ABOUTME: Discrete entitlements hold named units of a finite resource, and holds occupy units for a while.
# ABOUTME: Capacity is read live under a lock on the resource, so racing grants and holds never overrun it.
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
use POSIX ();

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $SLUG = 'seat_house';
Registry::DAO::Tenant->create( $db, { name => 'Seat House', slug => $SLUG } );
$db->query( 'SELECT clone_schema(dest_schema => ?)', $SLUG );
my $studio = Registry::DAO->new( url => $dao->url, schema => $SLUG )->db;

my $PAST   = '2020-01-01T00:00:00Z';
my $FUTURE = '2099-01-01T00:00:00Z';

my $people = 0;
sub person ($name = 'p' . ++$people) {
    return $studio->insert( 'users', { username => "$name-$people" }, { returning => 'id' } )
        ->hash->{id};
}

# A workflow run in the studio, to hold units; returns its id.
sub run_id () {
    my $workflow = $studio->insert( 'workflows', { slug => 'book-' . ++$people, name => "Book $people" },
        { returning => 'id' } )->hash->{id};
    return $studio->insert( 'workflow_runs', { workflow_id => $workflow }, { returning => 'id' } )
        ->hash->{id};
}

# A hold of $units units of $resource for ten minutes.
sub hold ( $handle, $resource, $units ) {
    return Registry::PriceOps::Hold->place( $handle, {
        resource_id     => $resource->id,
        units           => $units,
        workflow_run_id => run_id(),
        expires_at      => \"now() + interval '10 minutes'",
    } );
}

# A finite resource of $capacity units and a published version that buys it.
sub seats ( $capacity = 10 ) {
    my $resource = Registry::DAO::Resource->create( $studio,
        { name => 'Wheel seats', kind => 'finite', capacity => $capacity } );
    my $version = Registry::DAO::Offer->create( $studio, { name => 'Wheel class' } )
        ->draft( $studio, offer_terms( $resource->id ) )->publish($studio);
    return ( $resource, $version );
}

# What every grant of $version's units to $holder needs besides the units.
sub sale ( $version, $holder, %more ) {
    return {
        holder_user_id   => $holder,
        offer_version_id => $version->id,
        payment_plan_id  => 'pay',
        resource_id      => $version->resource_id,
        starts_at        => $PAST,
        %more,
    };
}

# Two real connections and a fork, as one connection cannot interleave with
# itself. A runs $first inside an open transaction; B then runs $second and
# must wait for A's lock. Returns how B ended: 'ok', 'refused' (capacity) or
# the error.
sub race ( $first, $second ) {
    my $uri = $test_db->uri;
    pipe( my $child_reads, my $parent_writes ) or die "pipe: $!";
    my $pid = fork() // die "fork: $!";
    unless ($pid) {
        close $parent_writes;
        readline $child_reads;
        my $bdb = Registry::DAO->new( url => $uri, schema => $SLUG )->db;
        my $ok  = eval { $second->($bdb); 1 };
        POSIX::_exit(0) if $ok;
        POSIX::_exit(3) if $@ =~ /units free/;
        print STDERR "second connection failed: $@";
        POSIX::_exit(1);
    }
    close $child_reads;
    my $adb = Registry::DAO->new( url => $uri, schema => $SLUG )->db;
    my $tx  = $adb->begin;
    $first->($adb);
    print $parent_writes "go\n";
    $parent_writes->flush;
    sleep 1;    # let B reach the resource and block behind A
    $tx->commit;
    waitpid $pid, 0;
    return { 0 => 'ok', 3 => 'refused' }->{ $? >> 8 } // 'failed';
}

subtest 'entitlement holds named units of a resource' => sub {
    my ( $resource, $version ) = seats(10);
    my $e = Registry::DAO::Entitlement->grant( $studio, sale( $version, person(), units => 2 ) );

    is_deeply $e->units( $studio, $resource->id ), [ 1, 2 ],
        'the grant records the two specific units it holds';
    my $named = Registry::DAO::Entitlement->grant( $studio,
        sale( $version, person(), unit_numbers => [7] ) );
    is_deeply $named->units( $studio, $resource->id ), [7], 'or the unit the sale names';
};

subtest 'holder check names the resource' => sub {
    my ( $resource, $version ) = seats(10);
    my ( $sam, $pat ) = ( person(), person() );
    Registry::DAO::Entitlement->grant( $studio, sale( $version, $sam, units => 2 ) );

    ok Registry::DAO::Entitlement->holds_unit_of( $studio, $sam, $resource->id ),
        'the holder holds a unit of the resource';
    ok !Registry::DAO::Entitlement->holds_unit_of( $studio, $pat, $resource->id ),
        'another person does not';
    my ( $other ) = seats(10);
    ok !Registry::DAO::Entitlement->holds_unit_of( $studio, $sam, $other->id ),
        'and the holder holds no unit of another resource';
};

subtest 'free units count held entitlements' => sub {
    my ( $resource, $version ) = seats(10);
    is $resource->free_units($studio), 10, 'an empty resource has all its units free';

    Registry::DAO::Entitlement->grant( $studio, sale( $version, person(), units => 2 ) );
    is $resource->free_units($studio), 8, 'two units held by an in-effect entitlement leave 8';

    Registry::DAO::Entitlement->grant( $studio,
        sale( $version, person(), units => 1, starts_at => $FUTURE ) );
    is $resource->free_units($studio), 7, 'a future-dated entitlement occupies its unit too';
};

subtest 'grant beyond capacity refused' => sub {
    my ( $resource, $version ) = seats(2);
    Registry::DAO::Entitlement->grant( $studio,
        sale( $version, person(), units => 2, ends_at => '2021-01-01T00:00:00Z' ) );
    is $resource->free_units($studio), 2, 'an entitlement whose period has ended holds nothing';

    Registry::DAO::Entitlement->grant( $studio, sale( $version, person(), units => 2 ) );
    my $resource_id = $resource->id;
    throws_ok { Registry::DAO::Entitlement->grant( $studio, sale( $version, person(), units => 1 ) ) }
        qr/Wheel seats \($resource_id\) has 0 of 2 units free/,
        'a grant past capacity is refused, naming the resource';
    is $resource->free_units($studio), 0, 'and capacity is not overrun';
};

subtest 'concurrent grants of the last unit never overrun' => sub {
    my ( $resource, $version ) = seats(1);
    my ( $sam, $pat ) = ( person(), person() );
    my $grant = sub ($holder) {
        sub ($handle) { Registry::DAO::Entitlement->grant( $handle, sale( $version, $holder, units => 1 ) ) }
    };

    is race( $grant->($sam), $grant->($pat) ), 'refused', 'the second grant waits for the first and is refused';
    is $studio->query( 'SELECT count(*) FROM entitlement_units WHERE resource_id = ?',
        $resource->id )->array->[0], 1, 'exactly one unit was granted';
    is $resource->free_units($studio), 0, 'and capacity is never exceeded';
};

subtest 'live holds occupy units' => sub {
    my ( $resource, $version ) = seats(10);
    Registry::DAO::Entitlement->grant( $studio, sale( $version, person(), units => 6 ) );

    my $hold = hold( $studio, $resource, 3 );
    is $hold->state, 'held', 'a placed hold is held';
    is $resource->free_units($studio), 1, 'six units sold and three held leave one free';
    throws_ok { Registry::DAO::Entitlement->grant( $studio, sale( $version, person(), units => 2 ) ) }
        qr/has 1 of 10 units free: 2 asked for/, 'so a further grant of two is refused';
};

subtest 'lapsed or released holds free their units' => sub {
    my ( $resource ) = seats(4);
    my ( $kept, $dropped ) = ( hold( $studio, $resource, 2 ), hold( $studio, $resource, 2 ) );
    is $resource->free_units($studio), 0, 'two live holds of two fill four units';

    my $released = $dropped->release($studio);
    is $released->state, 'released', 'a released hold says so';
    is $resource->free_units($studio), 2, 'and no longer occupies its units';

    # Time passing, without waiting for it: nothing sweeps a lapsed hold.
    $studio->update( 'holds', { expires_at => \"now() - interval '1 second'" }, { id => $kept->id } );
    is $resource->free_units($studio), 4, 'a hold past its lapse time no longer occupies its units';
};

done_testing;
