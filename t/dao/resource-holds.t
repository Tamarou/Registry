#!/usr/bin/env perl
# ABOUTME: A time-limited hold on a finite resource's units lapses, releases or converts into entitlement units once.
# ABOUTME: Lapse needs no sweep: a hold stops counting the moment it lapses, even for a request already waiting on the lock.
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

my $SLUG = 'hold_house';
Registry::DAO::Tenant->create( $db, { name => 'Hold House', slug => $SLUG } );
$db->query( 'SELECT clone_schema(dest_schema => ?)', $SLUG );
my $studio = Registry::DAO->new( url => $dao->url, schema => $SLUG )->db;

my $PAST = '2020-01-01T00:00:00Z';
my $made = 0;

sub person () {
    return $studio->insert( 'users', { username => 'p-' . ++$made }, { returning => 'id' } )->hash->{id};
}

# A workflow run in the studio, to hold units; returns its id.
sub run_id () {
    my $workflow = $studio->insert( 'workflows', { slug => 'book-' . ++$made, name => "Book $made" },
        { returning => 'id' } )->hash->{id};
    return $studio->insert( 'workflow_runs', { workflow_id => $workflow }, { returning => 'id' } )
        ->hash->{id};
}

# A class with $count occurrences of $capacity seats, each its own resource,
# and a published class offer version covering them.
sub occurrences ( $count, $capacity = 2 ) {
    my $class = $studio->insert( 'projects', { name => 'Class ' . ++$made, slug => "class-$made" },
        { returning => 'id' } )->hash->{id};
    my @resources = map {
        my $teacher = person();
        my $room = $studio->insert( 'locations', { time_zone => 'America/New_York', name => 'Room ' . ++$made, slug => "room-$made" },
            { returning => 'id' } )->hash->{id};
        my $event = $studio->insert( 'events', {
            project_id => $class, location_id => $room, teacher_id => $teacher,
            time       => "2099-03-0${_}T10:00:00Z", duration => 90, capacity => $capacity,
        }, { returning => 'id' } )->hash->{id};
        Registry::DAO::Resource->for_occurrence( $studio, $event );
    } 1 .. $count;
    my $version = Registry::DAO::Offer->create( $studio, { name => 'Wheel class ' . $made } )
        ->draft( $studio, offer_terms( undef, class_project_id => $class ) )->publish($studio);
    return ( $version, @resources );
}

# A hold of $units units of $resource for $lifetime.
sub hold ( $handle, $resource, $units, $lifetime = '15 minutes', $run = run_id() ) {
    return Registry::PriceOps::Hold->place( $handle, {
        resource_id     => $resource->id,
        units           => $units,
        workflow_run_id => $run,
        expires_at      => \"now() + interval '$lifetime'",
    } );
}

# What an entitlement under $version needs besides its units.
sub sale ( $version, %more ) {
    return {
        holder_user_id   => person(),
        offer_version_id => $version->id,
        payment_plan_id  => 'pay',
        starts_at        => $PAST,
        %more,
    };
}

sub payment ($cents) {
    return $studio->insert( 'payments',
        { user_id => person(), amount_cents => $cents, status => 'completed' },
        { returning => 'id' } )->hash->{id};
}

sub entitlements_of ($version) {
    return $studio->query( 'SELECT count(*) FROM entitlements WHERE offer_version_id = ?', $version->id )
        ->array->[0];
}

sub hold_state ($hold) {
    return $studio->select( 'holds', 'state', { id => $hold->id } )->array->[0];
}

# Waits until a session is blocked behind backend $holder, or child $pid
# exits; returns whether one waited.
sub blocked_behind ( $holder, $pid ) {
    my ( $blocked, $deadline ) = ( 0, time + 30 );
    until ( $blocked || waitpid( $pid, POSIX::WNOHANG() ) || time > $deadline ) {
        select undef, undef, undef, 0.05;
        $blocked = $studio->query( 'SELECT count(*) FROM pg_stat_activity WHERE ? = ANY (pg_blocking_pids(pid))',
            $holder )->array->[0];
    }
    return $blocked;
}

# Two real connections. Everything B runs is built before the fork, as B must
# not touch the parent's connection. A opens a transaction and runs $first, which takes a
# resource lock. B then opens its own transaction, reads its clock and runs
# $second, which waits on A's lock. Once B waits, A runs $then and commits.
# Returns whether B waited and B's error ('' when it succeeded).
sub race ( $first, $second, $then = sub {} ) {
    my $uri = $test_db->uri;
    pipe( my $child_reads, my $parent_writes ) or die "pipe: $!";
    pipe( my $parent_reads, my $child_writes ) or die "pipe: $!";
    my $pid = fork() // die "fork: $!";
    unless ($pid) {
        forget_inherited_handles();
        close $_ for $parent_writes, $parent_reads;
        readline $child_reads;
        my $bdb = Registry::DAO->new( url => $uri, schema => $SLUG )->db;
        my $tx  = $bdb->begin;
        $bdb->query('SELECT now()');    # B's transaction starts before A's lock is released
        print $child_writes( eval { $second->($bdb); $tx->commit; 1 } ? '' : "$@" );
        close $child_writes;
        POSIX::_exit(0);
    }
    close $_ for $child_reads, $child_writes;
    my $adb = Registry::DAO->new( url => $uri, schema => $SLUG )->db;
    my $tx  = $adb->begin;
    $first->($adb);
    my $holder = $adb->query('SELECT pg_backend_pid()')->array->[0];
    print $parent_writes "go\n";
    $parent_writes->flush;
    my $blocked = blocked_behind( $holder, $pid );
    $then->($adb);
    $tx->commit;
    reap($pid);
    return ( $blocked, do { local $/; readline $parent_reads } // q{} );
}

subtest 'hold converts to entitlement units once' => sub {
    my ( $version, $seats ) = occurrences(1);
    my $hold = hold( $studio, $seats, 1 );
    is $seats->free_units($studio), 1, 'a 1-seat hold leaves one of two seats free';

    my $paid = payment(2000);
    my $e    = $hold->convert( $studio, sale( $version, payment_id => $paid, payment_share_cents => 2000 ) );
    is_deeply $e->units( $studio, $seats->id ), [1], 'the entitlement holds the held seat';
    is $e->payment_id, $paid, 'with its payment link set at insert';
    is hold_state($hold), 'converted', 'the hold reads converted';
    is $seats->free_units($studio), 1, 'the seat is counted once, as the entitlement';

    throws_ok { $hold->convert( $studio, sale($version) ) } qr/not live/, 'it converts only once';
    is entitlements_of($version), 1, 'so one entitlement holds its units';
};

subtest 'convert onto an existing entitlement creates no second entitlement' => sub {
    my ( $version, $a, $b ) = occurrences(2);
    my $paid = payment(2000);
    my $e = Registry::DAO::Entitlement->grant( $studio,
        sale( $version, resource_id => $a->id, units => 1, payment_id => $paid, payment_share_cents => 2000 ) );
    my $hold = hold( $studio, $b, 1 );

    my $moved = $hold->convert( $studio, $e );
    is $moved->id, $e->id, 'the same entitlement comes back';
    is_deeply $e->units( $studio, $b->id ), [1], 'it holds the unit of B';
    is_deeply $e->units( $studio, $a->id ), [], 'and none of A';
    is $a->free_units($studio), 2, "A's seat is free";
    is $b->free_units($studio), 1, "B's seat is counted once";
    is entitlements_of($version), 1, 'no second entitlement exists';
    my $read = Registry::DAO::Entitlement->find( $studio, { id => $e->id } );
    is $read->payment_id, $paid, 'it keeps its original payment link';
    is $read->state, 'active', 'and stays in effect';
    is $studio->query( 'SELECT count(*) FROM entitlements WHERE payment_id = ?', $paid )->array->[0], 1,
        'and no new entitlement carries a payment link';
    is hold_state($hold), 'converted', 'the hold reads converted';
};

subtest 'holds use the step 3 storage and check' => sub {
    my ( $version, $seats ) = occurrences(1);
    my $hold = hold( $studio, $seats, 2 );
    is $studio->select( 'holds', 'units', { id => $hold->id } )->array->[0], 2, 'the hold is a holds row';
    is_deeply $studio->query( q{
        SELECT array_agg(table_name::text ORDER BY table_name) FROM information_schema.tables
         WHERE table_schema = ? AND table_name LIKE '%hold%'
    }, $SLUG )->array->[0], ['holds'], 'and no other hold table exists';
    is $seats->free_units($studio), 0, "the resource's one check counts it";
    throws_ok { Registry::DAO::Entitlement->grant( $studio, sale( $version, resource_id => $seats->id, units => 1 ) ) }
        qr/has 0 of 2 units free/, 'so a grant of a held seat is refused';
};

subtest 'zero or past lifetime refused' => sub {
    my ( $version, $seats ) = occurrences(1);
    for my $expires ( \'now()', \"now() - interval '1 minute'", $PAST ) {
        throws_ok {
            Registry::PriceOps::Hold->place( $studio,
                { resource_id => $seats->id, units => 1, workflow_run_id => run_id(), expires_at => $expires } )
        } qr/must expire after it is placed/, 'a hold expiring at ' . ( ref $expires ? $$expires : $expires ) . ' is refused';
    }
    is $studio->query( 'SELECT count(*) FROM holds WHERE resource_id = ?', $seats->id )->array->[0], 0,
        'and none is stored';
};

subtest 'lapsed or released hold cannot convert' => sub {
    my ( $version, $seats ) = occurrences(1);
    my ( $lapsed, $released ) = ( hold( $studio, $seats, 1 ), hold( $studio, $seats, 1 ) );
    # Time passing, without waiting for it.
    $studio->update( 'holds', { expires_at => \"now() - interval '1 second'" }, { id => $lapsed->id } );
    $released->release($studio);

    for my $hold ( $lapsed, $released ) {
        throws_ok { $hold->convert( $studio, sale($version) ) } qr/not live/, 'converting it is refused';
    }
    is entitlements_of($version), 0, 'no entitlement was granted';
    is $studio->query( 'SELECT count(*) FROM entitlement_units WHERE resource_id = ?', $seats->id )->array->[0], 0,
        'and no units';
    is hold_state($lapsed), 'held', 'the lapsed hold is left as it was';

    my ( $other, $a, $b ) = occurrences(2);
    my $e    = Registry::DAO::Entitlement->grant( $studio, sale( $other, resource_id => $a->id, units => 1 ) );
    my $gone = hold( $studio, $b, 1 );
    $gone->release($studio);
    throws_ok { $gone->convert( $studio, $e ) } qr/not live/, 'nor can it convert onto an existing entitlement';
    is_deeply $e->units( $studio, $a->id ), [1], 'which keeps its unit';
};

subtest 'releasing converted hold frees nothing' => sub {
    my ( $version, $seats ) = occurrences(1);
    my $hold = hold( $studio, $seats, 2 );
    my $e    = $hold->convert( $studio, sale($version) );
    dies_ok { $hold->release($studio) } 'releasing a converted hold is refused';
    is hold_state($hold), 'converted', 'it still reads converted';
    is_deeply $e->units( $studio, $seats->id ), [ 1, 2 ], 'the entitlement keeps its units';
    is $seats->free_units($studio), 0, 'and no seat is freed';
};

subtest 'double convert grants units once' => sub {
    my ( $version, $seats ) = occurrences(1);
    my $hold = hold( $studio, $seats, 1 );
    $hold->convert( $studio, sale($version) );
    throws_ok { $hold->convert( $studio, sale($version) ) } qr/not live/, 'a second convert is refused';

    my $racing = hold( $studio, $seats, 1 );
    my ( $first, $second ) = ( sale($version), sale($version) );
    my ( $waited, $error ) = race(
        sub ($handle) { $racing->convert( $handle, $first ) },
        sub ($handle) { $racing->convert( $handle, $second ) },
    );
    ok $waited, 'the second connection waited for the first';
    like $error, qr/not live/, 'and was refused';
    is entitlements_of($version), 2, 'each hold granted one entitlement';
    is $studio->query( 'SELECT count(*) FROM entitlement_units WHERE resource_id = ?', $seats->id )->array->[0], 2,
        'holding one unit each';
};

subtest 'lapse under lock frees seats for waiting request' => sub {
    my $lapse = sub ($hold) {
        sub ($handle) { $handle->update( 'holds', { expires_at => \'clock_timestamp()' }, { id => $hold->id } ) }
    };

    my ( $version, $seats ) = occurrences( 1, 1 );
    my $held  = hold( $studio, $seats, 1 );
    my $grant = sale( $version, resource_id => $seats->id, units => 1 );
    my ( $waited, $error ) = race(
        sub ($handle) { Registry::DAO::Resource->locked( $handle, $seats->id ) },
        sub ($handle) { Registry::DAO::Entitlement->grant( $handle, $grant ) },
        $lapse->($held),
    );
    ok $waited, 'the grant waited on the resource lock';
    is $error, '', 'and took the seat once the hold lapsed';
    is $studio->query( 'SELECT count(*) FROM entitlement_units WHERE resource_id = ?', $seats->id )->array->[0], 1,
        'one seat is granted';

    my ( $later, $seat ) = occurrences( 1, 1 );
    my $old  = hold( $studio, $seat, 1 );
    my ( $run, $sold ) = ( run_id(), sale( $later, resource_id => $seat->id, units => 1 ) );
    ( $waited, $error ) = race(
        sub ($handle) { Registry::DAO::Resource->locked( $handle, $seat->id ) },
        sub ($handle) { hold( $handle, $seat, 1, '15 minutes', $run ) },
        sub ($handle) {
            $lapse->($old)->($handle);
            Registry::DAO::Entitlement->grant( $handle, $sold );
        },
    );
    ok $waited, 'a hold waited on the resource lock';
    like $error, qr/has 0 of 1 units free/, 'and is refused: the lapsed seat was taken under the lock';
    is $studio->query( q{SELECT count(*) FROM holds WHERE resource_id = ? AND state = 'held'}, $seat->id )
        ->array->[0], 1, 'only the lapsed hold is stored';
    is $seat->free_units($studio), 0, 'and capacity is never exceeded';
};

# Converts $hold onto $e inside the caller's own transaction, which catches
# the refusal and commits anyway; returns the error.
sub refused_in_callers_tx ( $hold, $e ) {
    my $tx = $studio->begin;
    my $ok = eval { $hold->convert( $studio, $e ); 1 };
    my $error = $@;
    $tx->commit;
    return $ok ? '' : $error;
}

subtest 'refused move leaves the hold held' => sub {
    my ( $version, $a, $b ) = occurrences(2);
    my $ended = Registry::DAO::Entitlement->grant( $studio, sale( $version, resource_id => $a->id, units => 1 ) );
    $ended->end( $studio, 'refunded', 're_move_1' );
    my $hold = hold( $studio, $b, 1 );
    like refused_in_callers_tx( $hold, $ended ), qr/units move only onto an active one/,
        'a move onto a refunded entitlement is refused';
    is hold_state($hold), 'held', 'the hold stays held';
    is_deeply $ended->units( $studio, $a->id ), [1], 'the entitlement keeps its unit';
    is_deeply $ended->units( $studio, $b->id ), [], 'and gains none';

    my ( $other, $c ) = occurrences(1);
    my $e = Registry::DAO::Entitlement->grant( $studio, sale( $other, resource_id => $c->id, units => 1 ) );
    like refused_in_callers_tx( $hold, $e ), qr/does not buy resource/,
        'a move onto a version that does not buy the resource is refused';
    is hold_state($hold), 'held', 'the hold stays held';
    is_deeply $e->units( $studio, $c->id ), [1], 'the entitlement keeps its unit';
    is_deeply $e->units( $studio, $b->id ), [], 'and gains none';
};

subtest 'move with a different seat count refused' => sub {
    my ( $version, $a, $b ) = occurrences(2);
    my $e    = Registry::DAO::Entitlement->grant( $studio, sale( $version, resource_id => $a->id, units => 2 ) );
    my $hold = hold( $studio, $b, 1 );
    like refused_in_callers_tx( $hold, $e ), qr/keeps its unit count/, 'a 1-seat hold cannot carry 2 seats';
    is hold_state($hold), 'held', 'the hold stays held';
    is_deeply $e->units( $studio, $a->id ), [ 1, 2 ], 'the entitlement keeps both seats';
};

subtest 'move onto an ended entitlement refused' => sub {
    my ( $version, $a, $b ) = occurrences(2);
    my $over = Registry::DAO::Entitlement->grant( $studio,
        sale( $version, resource_id => $a->id, units => 1, ends_at => '2021-01-01T00:00:00Z' ) );
    my $hold = hold( $studio, $b, 1 );
    like refused_in_callers_tx( $hold, $over ), qr/has ended/, 'an active entitlement whose period ended is refused';
    is hold_state($hold), 'held', 'the hold stays held';
    is_deeply $over->units( $studio, $a->id ), [1], 'the entitlement keeps its unit';

    my $later = Registry::DAO::Entitlement->grant( $studio,
        sale( $version, resource_id => $a->id, units => 1, starts_at => '2099-01-01T00:00:00Z' ) );
    $hold->convert( $studio, $later );
    is_deeply $later->units( $studio, $b->id ), [1], 'one not yet started takes the move';
};

subtest 'concurrent moves of one entitlement lock what they change' => sub {
    my ( $version, $a, $b ) = occurrences(2);
    my $e    = Registry::DAO::Entitlement->grant( $studio, sale( $version, resource_id => $a->id, units => 1 ) );
    my $hold = hold( $studio, $b, 1 );
    my ( $waited, $error ) = race(
        sub ($handle) { $e->end( $handle, 'refunded', 're_race_1' ) },
        sub ($handle) { $hold->convert( $handle, $e ) },
    );
    ok $waited, 'a move waits on the entitlement another transaction is changing';
    like $error, qr/units move only onto an active one/, 'and then sees it ended';
    is hold_state($hold), 'held', 'the hold stays held';
    is_deeply $e->units( $studio, $a->id ), [1], 'the entitlement keeps its unit';
};

done_testing;
