#!/usr/bin/env perl
# ABOUTME: The expire_entitlements sweep ends occurrence-bound entitlements once their occurrence is over.
# ABOUTME: Real Minion on real Postgres, across registry and provisioned tenants; policy read from the stamped version.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Fork qw( forget_inherited_handles reap );
use Test::Registry::DB;
use Test::Registry::Mojo;
use Test::Registry::Offers qw( offer_terms );
use Registry::DAO;
use Registry::DAO::User;
use Registry::DAO::Tenant;
use Registry::DAO::Resource;
use Registry::DAO::Offer;
use Registry::DAO::Entitlement;
use Registry::PriceOps::Hold;
use POSIX ();

my $test_db  = Test::Registry::DB->new;
my $dao      = $test_db->db;
my $registry = $dao->db;
my $t        = Test::Registry::Mojo->new('Registry');
my $app      = $t->app;
my $minion   = $app->minion;
$app->log->level('fatal');

my $made = 0;

sub tenant ($slug) {
    my $admin = Registry::DAO::User->create( $registry, {
        username => "admin-$slug", name => "Admin $slug", email => "admin-$slug\@test.example",
        user_type => 'admin' } );
    Registry::DAO::Tenant->provision( $registry, { name => "Tenant $slug", slug => $slug, users => [$admin] } );
    return Registry::DAO->new( url => $dao->url, schema => $slug )->db;
}

my $studio = tenant('expiry_house');

sub person ($db) {
    return $db->insert( 'users', { username => 'p-' . ++$made }, { returning => 'id' } )->hash->{id};
}

# A class in $db with an occurrence of 90 minutes starting at each of
# @starts (SQL intervals from now), each its own resource.
sub occurrences ( $db, @starts ) {
    my $class = $db->insert( 'projects', { name => 'Class ' . ++$made, slug => "class-$made" },
        { returning => 'id' } )->hash->{id};
    my @resources = map {
        my $room = $db->insert( 'locations', { time_zone => 'America/New_York', name => 'Room ' . ++$made, slug => "room-$made" },
            { returning => 'id' } )->hash->{id};
        my $event = $db->insert( 'events', {
            project_id => $class, location_id => $room, teacher_id => person($db),
            time => \[ 'now() + ?::interval', $_ ], duration => 90, capacity => 4,
        }, { returning => 'id' } )->hash->{id};
        Registry::DAO::Resource->for_occurrence( $db, $event );
    } @starts;
    return ( $class, @resources );
}

my $ENDED = '-150 minutes';    # ended an hour ago
my $AHEAD = '24 hours';

# A published version selling $where ({ resource_id } or { class_project_id })
# with expiry $expiry; given $offer, a new version of it superseding the last.
sub version ( $db, $where, $expiry, $offer = undef ) {
    $offer //= Registry::DAO::Offer->create( $db, { name => 'Offer ' . ++$made } );
    return $offer->draft( $db, offer_terms( undef, %$where,
        policies => { refund => { kind => 'none' }, expiry => { kind => $expiry } } ) )->publish($db);
}

sub booking ( $db, $version, $resource, %more ) {
    return Registry::DAO::Entitlement->grant( $db, {
        holder_user_id => person($db), offer_version_id => $version->id, payment_plan_id => 'pay',
        starts_at => '2020-01-01T00:00:00Z', resource_id => $resource->id, units => 1, %more } );
}

# An occurrence-bound booking under an end_of_occurrence version, on an
# occurrence starting at $start.
sub bound_booking ( $db, $start ) {
    my ( undef, $resource ) = occurrences( $db, $start );
    my $version = version( $db, { resource_id => $resource->id }, 'end_of_occurrence' );
    return ( booking( $db, $version, $resource ), $resource, $version );
}

sub reread ( $db, $e ) { Registry::DAO::Entitlement->find( $db, { id => $e->id } ) }

sub run_sweep () {
    my $id = $minion->enqueue('expire_entitlements');
    $minion->perform_jobs_in_foreground( { id => $id } );
    return $minion->job($id)->info;
}

sub expired_in ( $info, $slug ) { $info->{result}{expired}{$slug} // [] }

subtest 'ended occurrence expires under stamped policy' => sub {
    my ( $over, $resource, $sold_under ) = bound_booking( $studio, $ENDED );
    my ($ahead) = bound_booking( $studio, $AHEAD );
    # Republished as never-expiring after the sale: the sale keeps its stamp.
    version( $studio, { resource_id => $resource->id }, 'never',
        Registry::DAO::Offer->find( $studio, { id => $sold_under->offer_id } ) );

    my $info = run_sweep();
    is $info->{state}, 'finished', 'the sweep finished';

    my $now = reread( $studio, $over );
    is $now->state, 'expired', 'the entitlement on the ended occurrence is expired';
    my ( undef, $ends ) = $resource->occurrence_window($studio);
    ok $studio->query( 'SELECT ?::timestamptz = ?::timestamptz', $now->ended_at, $ends )->array->[0],
        'its expiry time is when its occurrence ended';
    ok defined $now->ended_reason, 'with a reason';
    is $resource->free_units($studio), 4, 'and its seat is free again';
    is_deeply expired_in( $info, 'expiry_house' ), [ $over->id ], 'the sweep reports what it expired';

    is reread( $studio, $ahead )->state, 'active', 'the entitlement on tomorrow\'s occurrence is still active';
};

subtest 'no end of occurrence policy means no expiry' => sub {
    my ( undef, $resource ) = occurrences( $studio, $ENDED );
    my $never = version( $studio, { resource_id => $resource->id }, 'never' );
    my $e     = booking( $studio, $never, $resource );
    # Republished as expiring after the sale: the sale keeps its stamp.
    version( $studio, { resource_id => $resource->id }, 'end_of_occurrence',
        Registry::DAO::Offer->find( $studio, { id => $never->offer_id } ) );

    run_sweep();
    is reread( $studio, $e )->state, 'active', 'sold under never: still active after its occurrence ended';
};

subtest 'ended entitlement keeps its ending reason' => sub {
    my ($refunded) = bound_booking( $studio, $ENDED );
    my ($disputed) = bound_booking( $studio, $ENDED );
    $refunded->end( $studio, 'refunded', 're_full' );
    $disputed->end( $studio, 'dispute_lost', 'dp_lost' );

    my $info = run_sweep();
    is $info->{state}, 'finished', 'the sweep finished';
    is_deeply $info->{result}{tenants_skipped}, [], 'with no tenant failing on them';
    my ( $r, $d ) = map { reread( $studio, $_ ) } $refunded, $disputed;
    is_deeply [ $r->state, $r->ended_reason ], [ 'refunded',     're_full' ], 'the refunded one keeps its ending';
    is_deeply [ $d->state, $d->ended_reason ], [ 'dispute_lost', 'dp_lost' ], 'the disputed one keeps its ending';
};

subtest 'moved entitlement follows its current occurrence' => sub {
    my ( $class, $past, $future ) = occurrences( $studio, $ENDED, $AHEAD );
    my $version = version( $studio, { class_project_id => $class }, 'end_of_occurrence' );
    my $e       = booking( $studio, $version, $past );
    my $run = $studio->insert( 'workflow_runs', {
        workflow_id => $studio->insert( 'workflows', { slug => 'move-' . ++$made, name => 'Move' },
            { returning => 'id' } )->hash->{id} }, { returning => 'id' } )->hash->{id};
    Registry::PriceOps::Hold->place( $studio, { resource_id => $future->id, units => 1,
        workflow_run_id => $run, expires_at => \"now() + interval '10 minutes'" } )->convert( $studio, $e );

    run_sweep();
    is reread( $studio, $e )->state, 'active', 'moved onto an occurrence still ahead, it is not expired';
};

subtest 'expiry changes only state and expiry time' => sub {
    my ( $class, $over_r, $ahead_r ) = occurrences( $studio, $ENDED, $AHEAD );
    my $version = version( $studio, { class_project_id => $class }, 'end_of_occurrence' );
    my $over  = booking( $studio, $version, $over_r, units => 2 );
    my $ahead = booking( $studio, $version, $ahead_r, units => 2 );
    my $rows  = sub ($e) {
        $studio->query( 'SELECT * FROM entitlements WHERE id = ?', $e->id )->expand->hash;
    };
    my $units = sub {
        $studio->query( 'SELECT entitlement_id, resource_id, unit FROM entitlement_units
                          WHERE entitlement_id IN (?, ?) ORDER BY 1, 2, 3', $over->id, $ahead->id )->hashes;
    };
    my ( $before_over, $before_ahead, $before_units ) = ( $rows->($over), $rows->($ahead), $units->() );

    run_sweep();
    my $after_over = $rows->($over);
    is $after_over->{state}, 'expired', 'it expired';
    delete @{$_}{qw( state ended_at ended_reason in_effect )} for $before_over, $after_over;
    is_deeply $after_over, $before_over, 'nothing else about it changed';
    is_deeply $rows->($ahead), $before_ahead, 'the other entitlement is untouched';
    is_deeply $units->(), $before_units, 'every held unit row is as it was';
};

subtest 'sweep covers registry and recurs' => sub {
    my ($platform) = bound_booking( $registry, $ENDED );
    $minion->reset( { all => 1 } );
    $app->setup_recurring_jobs;
    my $jobs = sub { $minion->jobs( { tasks => ['expire_entitlements'], states => ['inactive'] } ) };
    is $jobs->()->total, 1, 'setup_recurring_jobs seeds the sweep';

    my $run_next = sub {
        my $id = $jobs->()->next->{id};
        $minion->backend->pg->db->query( q{UPDATE minion_jobs SET delayed = now() WHERE id = ?}, $id );
        $minion->perform_jobs;
        return $minion->job($id)->info;
    };
    my $first = $run_next->();
    is $first->{state}, 'finished', 'the first run finished';
    ok( ( grep { $_ eq 'registry' } $first->{result}{tenants_covered}->@* ), 'it covered registry' );
    is reread( $registry, $platform )->state, 'expired', "registry's ended entitlement is expired";
    is_deeply expired_in( $first, 'registry' ), [ $platform->id ], 'and reported for registry';
    is $jobs->()->total, 1, 'it queued its own next run';

    my $second = $run_next->();
    is $second->{state}, 'finished', 'the second run finished';
    is_deeply $second->{result}{expired}, {}, 'and expired nothing already expired';
    is $jobs->()->total, 1, 'and queued the next';
};

subtest 'concurrent sweeps expire once' => sub {
    my @bookings = map { ( bound_booking( $studio, $ENDED ) )[0] } 1 .. 3;
    my $uri = $test_db->uri;
    pipe( my $child_reads,  my $parent_writes ) or die "pipe: $!";
    pipe( my $parent_reads, my $child_writes )  or die "pipe: $!";
    my $pid = fork() // die "fork: $!";
    unless ($pid) {
        forget_inherited_handles();
        close $parent_writes;
        close $parent_reads;
        readline $child_reads;
        my $bdb = Registry::DAO->new( url => $uri, schema => 'expiry_house' )->db;
        my $ids = eval { Registry::DAO::Entitlement->expire_ended_occurrences($bdb) };
        print $child_writes $ids ? join( ',', @$ids ) . "\n" : "ERROR $@\n";
        close $child_writes;
        POSIX::_exit(0);
    }
    close $child_reads;
    close $child_writes;
    my $adb = Registry::DAO->new( url => $uri, schema => 'expiry_house' )->db;
    my $tx  = $adb->begin;
    my $a   = Registry::DAO::Entitlement->expire_ended_occurrences($adb);
    print $parent_writes "go\n";
    $parent_writes->flush;
    sleep 1;    # let B read the same rows and block behind A
    $tx->commit;
    chomp( my $b = readline($parent_reads) // '' );
    reap($pid);
    unlike $b, qr/^ERROR/, 'the second sweep did not fail';

    my %seen;
    $seen{$_}++ for @$a, grep {length} split /,/, $b;
    is_deeply [ sort keys %seen ], [ sort map { $_->id } @bookings ], 'together they report each expiry';
    is_deeply [ grep { $seen{$_} > 1 } keys %seen ], [], 'and none twice';
    is reread( $studio, $_ )->state, 'expired', 'each is expired' for @bookings;
};

subtest 'tenant error does not stop other tenants' => sub {
    my $broken = tenant('expiry_broken');
    my $other  = tenant('expiry_other');
    my ($in_registry) = bound_booking( $registry, $ENDED );
    my ($in_other)    = bound_booking( $other, $ENDED );
    $registry->query('ALTER TABLE expiry_broken.entitlements RENAME TO entitlements_gone');

    my $info = run_sweep();
    is $info->{state}, 'finished', 'the sweep finished';
    ok( ( grep { $_->{slug} eq 'expiry_broken' } $info->{result}{tenants_skipped}->@* ),
        'it reported the broken tenant' );
    is reread( $registry, $in_registry )->state, 'expired', "registry's entitlement was expired";
    is reread( $other, $in_other )->state, 'expired', "the other tenant's entitlement was expired";
};

done_testing;
