#!/usr/bin/env perl
# ABOUTME: Discrete entitlements hold named units of a finite resource, and holds occupy units for a while.
# ABOUTME: Capacity is read live under a lock on the resource, so racing grants and holds never overrun it.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Fork qw( forget_inherited_handles reap );
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
sub hold ( $handle, $resource, $units, $run = run_id() ) {
    return Registry::PriceOps::Hold->place( $handle, {
        resource_id     => $resource->id,
        units           => $units,
        workflow_run_id => $run,
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
        forget_inherited_handles();
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
    reap($pid);
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

# Counts of what a refused claim might have left behind on $resource.
sub rows_for ($resource) {
    return $studio->query( q{
        SELECT (SELECT count(*) FROM entitlement_units WHERE resource_id = $1),
               (SELECT count(*) FROM holds WHERE resource_id = $1)
    }, $resource->id )->array;
}

subtest 'zero or negative units refused' => sub {
    my ( $resource, $version ) = seats(10);
    my $before = $studio->query('SELECT count(*) FROM entitlements')->array->[0];
    for my $units ( 0, -1 ) {
        throws_ok { Registry::DAO::Entitlement->grant( $studio, sale( $version, person(), units => $units ) ) }
            qr/at least one unit/, "a grant of $units units is refused";
    }
    throws_ok { Registry::DAO::Entitlement->grant( $studio, sale( $version, person(), unit_numbers => [] ) ) }
        qr/at least one unit/, 'as is a grant naming no unit';
    is $studio->query('SELECT count(*) FROM entitlements')->array->[0], $before,
        'and no entitlement is stored';
};

subtest 'unbought or foreign resource refused' => sub {
    my ( $resource, $version ) = seats(10);
    my ( $other ) = seats(10);
    my $other_id = $other->id;
    throws_ok {
        Registry::DAO::Entitlement->grant( $studio,
            sale( $version, person(), units => 1, resource_id => $other_id ) )
    } qr/does not buy resource $other_id/, 'units of a resource the version does not buy are refused';
    is_deeply rows_for($other), [ 0, 0 ], 'and none are stored';

    my $sends = Registry::DAO::Resource->create( $studio, { name => 'Sends', kind => 'unbounded' } );
    my $send_version = Registry::DAO::Offer->create( $studio, { name => 'Sends plan' } )
        ->draft( $studio, offer_terms( $sends->id ) )->publish($studio);
    throws_ok { Registry::DAO::Entitlement->grant( $studio, sale( $send_version, person(), units => 1 ) ) }
        qr/Sends .* has no units to hold/, 'an unbounded resource has no discrete units to grant';

    my $registry_only = Registry::DAO::Resource->create( $db,
        { name => 'Platform seats', kind => 'finite', capacity => 10 } )->id;
    for my $absent ( $registry_only, '00000000-0000-4000-8000-000000000001' ) {
        throws_ok {
            Registry::DAO::Entitlement->grant( $studio,
                sale( $version, person(), units => 1, resource_id => $absent ) )
        } qr/no resource $absent here/, "a resource id absent from this schema is refused ($absent)";
    }
};

subtest 'oversized grant refused atomically' => sub {
    my ( $resource, $version ) = seats(10);
    my $before = $studio->query( 'SELECT count(*) FROM entitlements WHERE offer_version_id = ?',
        $version->id )->array->[0];
    throws_ok { Registry::DAO::Entitlement->grant( $studio, sale( $version, person(), units => 11 ) ) }
        qr/has 10 of 10 units free: 11 asked for/, 'eleven units of an empty ten are refused';
    is $studio->query( 'SELECT count(*) FROM entitlements WHERE offer_version_id = ?',
        $version->id )->array->[0], $before, 'no entitlement row is left';
    is_deeply rows_for($resource), [ 0, 0 ], 'no units are left';
    is $resource->free_units($studio), 10, 'and free units are unchanged';
};

subtest 'held unit cannot be granted twice' => sub {
    my ( $resource, $version ) = seats(10);
    Registry::DAO::Entitlement->grant( $studio, sale( $version, person(), unit_numbers => [3] ) );
    throws_ok {
        Registry::DAO::Entitlement->grant( $studio, sale( $version, person(), unit_numbers => [ 4, 3 ] ) )
    } qr/unit 3 of Wheel seats .* is not free/, 'a unit held by an in-effect entitlement is refused';
    throws_ok {
        Registry::DAO::Entitlement->grant( $studio, sale( $version, person(), unit_numbers => [ 5, 5 ] ) )
    } qr/unit 5 of Wheel seats .* is not free/, 'as is naming one unit twice';
    throws_ok {
        Registry::DAO::Entitlement->grant( $studio, sale( $version, person(), unit_numbers => [11] ) )
    } qr/unit 11 of Wheel seats .* is not free/, 'and a unit past the capacity';
    is_deeply rows_for($resource), [ 1, 0 ], 'only the first grant holds a unit';
};

subtest 'concurrent partial grants leave one' => sub {
    my ( $resource, $version ) = seats(3);
    my ( $sam, $pat ) = ( person(), person() );
    my $grant = sub ($holder) {
        sub ($handle) { Registry::DAO::Entitlement->grant( $handle, sale( $version, $holder, units => 2 ) ) }
    };

    is race( $grant->($sam), $grant->($pat) ), 'refused', 'the second grant of two is refused';
    is_deeply rows_for($resource), [ 2, 0 ], 'exactly one grant holds units';
    is $resource->free_units($studio), 1, 'and one unit is free';
};

subtest 'future dated entitlement occupies units' => sub {
    my ( $resource, $version ) = seats(2);
    Registry::DAO::Entitlement->grant( $studio,
        sale( $version, person(), units => 2, starts_at => $FUTURE ) );
    throws_ok { Registry::DAO::Entitlement->grant( $studio, sale( $version, person(), units => 1 ) ) }
        qr/has 0 of 2 units free/, 'a grant for now cannot take seats sold for later';
    throws_ok {
        Registry::DAO::Entitlement->grant( $studio,
            sale( $version, person(), units => 1, starts_at => '2098-01-01T00:00:00Z' ) )
    } qr/has 0 of 2 units free/, 'nor can another future-dated grant';
};

subtest 'holder check false after entitlement ends' => sub {
    my ( $resource, $version ) = seats(10);
    my $sam = person();
    Registry::DAO::Entitlement->grant( $studio,
        sale( $version, $sam, units => 1, ends_at => '2021-01-01T00:00:00Z' ) );
    ok !Registry::DAO::Entitlement->holds_unit_of( $studio, $sam, $resource->id ),
        'a holder whose entitlement has ended holds no unit';
};

subtest 'hold and grant race for the last unit leave one' => sub {
    my ( $resource, $version ) = seats(1);
    my ( $sam, $run ) = ( person(), run_id() );
    my $grant = sub ($handle) {
        Registry::DAO::Entitlement->grant( $handle, sale( $version, $sam, units => 1 ) );
    };
    my $hold = sub ($handle) { hold( $handle, $resource, 1, $run ) };

    is race( $hold, $grant ), 'refused', 'a sale behind a hold on the last unit is refused';
    is_deeply rows_for($resource), [ 0, 1 ], 'the hold won';

    my ( $seat, $version2 ) = seats(1);
    my $run2 = run_id();
    my $sale2 = sub ($handle) {
        Registry::DAO::Entitlement->grant( $handle, sale( $version2, $sam, units => 1 ) );
    };
    is race( $sale2, sub ($handle) { hold( $handle, $seat, 1, $run2 ) } ), 'refused',
        'a hold behind a sale of the last unit is refused';
    is_deeply rows_for($seat), [ 1, 0 ], 'the sale won';
    is $seat->free_units($studio), 0, 'and capacity is never exceeded';
};

subtest 'invalid hold refused' => sub {
    my ( $resource ) = seats(2);
    for my $units ( 0, -1 ) {
        throws_ok { hold( $studio, $resource, $units ) } qr/at least one unit/,
            "a hold of $units units is refused";
    }
    throws_ok { hold( $studio, $resource, 3 ) } qr/has 2 of 2 units free: 3 asked for/,
        'a hold larger than the free units is refused';
    is_deeply rows_for($resource), [ 0, 0 ], 'and nothing is stored';
};

done_testing;
