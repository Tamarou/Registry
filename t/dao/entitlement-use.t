#!/usr/bin/env perl
# ABOUTME: Use as optional attendance: marking someone present records one use of the entitlement they hold.
# ABOUTME: Drives RecordEntitlementUse against real tenant schemas; an unmarked entitlement stays valid.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Offers qw( offer_terms );
use Registry::DAO::Resource;
use Registry::DAO::Offer;
use Registry::DAO::OfferVersion;
use Registry::DAO::Entitlement;
use Registry::DAO::Tenant;
use Registry::DAO::WorkflowSteps::RecordEntitlementUse;
use POSIX ();
use Mojo::JSON ();

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

# A tenant provisioned the way signup provisions one: the row, then its schema.
sub new_tenant ($slug) {
    Registry::DAO::Tenant->create( $db, { name => "Studio $slug", slug => $slug } );
    $db->query( 'SELECT clone_schema(dest_schema => ?)', $slug );
    return Registry::DAO->new( url => $dao->url, schema => $slug )->db;
}

my $SLUG   = 'use_house';
my $studio = new_tenant($SLUG);
my $made   = 0;

sub person ( $handle = $studio ) {
    return $handle->insert( 'users', { username => 'p-' . ++$made }, { returning => 'id' } )->hash->{id};
}

# An occurrence starting $hours from now, its own finite resource.
sub occurrence ( $hours = 24, $handle = $studio ) {
    my $class = $handle->insert( 'projects', { name => 'Class ' . ++$made, slug => "class-$made" },
        { returning => 'id' } )->hash->{id};
    my $room = $handle->insert( 'locations', { name => 'Room ' . ++$made, slug => "room-$made" },
        { returning => 'id' } )->hash->{id};
    my $event = $handle->insert( 'events', {
        project_id => $class, location_id => $room, teacher_id => person($handle),
        time       => \"now() + interval '$hours hours'", duration => 90, capacity => 4,
    }, { returning => 'id' } )->hash->{id};
    return Registry::DAO::Resource->for_occurrence( $handle, $event );
}

# An entitlement holding one seat of a new occurrence under use policy $use,
# in effect until the occurrence ends. Returns it and the occurrence.
sub booking ( $use = 'optional_attendance', $handle = $studio ) {
    my $occurrence = occurrence( 24, $handle );
    my $version = Registry::DAO::Offer->create( $handle, { name => 'Wheel ' . ++$made } )
        ->draft( $handle, offer_terms( $occurrence->id,
            policies => { refund => { kind => 'none' }, use => { kind => $use } } ) )->publish($handle);
    my ( undef, $ends ) = $occurrence->occurrence_window($handle);
    my $e = Registry::DAO::Entitlement->grant( $handle, {
        holder_user_id   => person($handle),
        offer_version_id => $version->id,
        payment_plan_id  => 'pay',
        starts_at        => '2020-01-01T00:00:00Z',
        ends_at          => $ends,
        resource_id      => $occurrence->id,
        units            => 1,
    } );
    return ( $e, $occurrence );
}

my $step = Registry::DAO::WorkflowSteps::RecordEntitlementUse->new(
    id => 1, slug => 'record-use', workflow_id => 1,
    description => 'test', class => 'Registry::DAO::WorkflowSteps::RecordEntitlementUse',
);
my $staff = person();

sub record ( $e, $occurrence, $handle = $studio ) {
    return $step->process( $handle,
        { entitlement_id => $e->id, occurrence_id => $occurrence->id, user_id => $staff } );
}

sub uses ( $e, $handle = $studio ) {
    return $handle->select( 'entitlement_uses', '*', { entitlement_id => $e->id } )->hashes->to_array;
}

# Holds $first's transaction open in one connection while $second runs in a
# forked one; once $second waits on $first's locks, $first commits. Returns
# whether $second waited and what it returned.
sub race ( $first, $second ) {
    my $uri = $test_db->uri;
    pipe( my $parent_reads, my $child_writes ) or die "pipe: $!";
    my $adb = Registry::DAO->new( url => $uri, schema => $SLUG )->db;
    my $tx  = $adb->begin;
    $first->($adb);
    my $holder = $adb->query('SELECT pg_backend_pid()')->array->[0];
    my $pid    = fork() // die "fork: $!";
    unless ($pid) {
        close $parent_reads;
        my $bdb = Registry::DAO->new( url => $uri, schema => $SLUG )->db;
        my $out = eval { Mojo::JSON::to_json( $second->($bdb) ) } // Mojo::JSON::to_json( { died => "$@" } );
        print $child_writes $out;
        close $child_writes;
        POSIX::_exit(0);
    }
    close $child_writes;
    my ( $blocked, $deadline ) = ( 0, time + 30 );
    until ( $blocked || waitpid( $pid, POSIX::WNOHANG() ) || time > $deadline ) {
        select undef, undef, undef, 0.05;
        $blocked = $studio->query( 'SELECT count(*) FROM pg_stat_activity WHERE ? = ANY (pg_blocking_pids(pid))',
            $holder )->array->[0];
    }
    $tx->commit;
    waitpid $pid, 0;
    return ( $blocked, Mojo::JSON::from_json( do { local $/; readline $parent_reads } ) );
}

subtest 'attendance records exactly one use' => sub {
    my ( $e, $occurrence ) = booking();
    my $result = record( $e, $occurrence );
    ok !$result->{errors}, 'recording attendance is accepted' or diag explain $result;
    my $uses = uses($e);
    is scalar @$uses, 1, 'one use is recorded';
    is $uses->[0]{occurrence_id}, $occurrence->id, 'against its occurrence';
    is $uses->[0]{recorded_by},   $staff,          'by the staff member who marked it';
    ok defined $uses->[0]{recorded_at}, 'with when';

    $result = record( $e, $occurrence );
    ok !$result->{errors}, 'marking it again is accepted' or diag explain $result;
    is scalar @{ uses($e) }, 1, 'and still leaves one use';
};

subtest 'unused entitlement stays active' => sub {
    my ( $e, $occurrence ) = booking();
    my ( $starts, $ends ) = $occurrence->occurrence_window($studio);
    is_deeply uses($e), [], 'nothing marks it used';
    ok $e->is_in_effect($studio), 'it is in effect now';
    my $last = $studio->query( q{SELECT ?::timestamptz - interval '1 second'}, $ends )->array->[0];
    ok $e->is_in_effect( $studio, $last ), 'and until its occurrence ends';
    ok !$e->is_in_effect( $studio, $ends ), 'expiring when it ends';
    is Registry::DAO::Entitlement->find( $studio, { id => $e->id } )->state, 'active', 'still active, unused';
};

subtest 'use of ended entitlement refused' => sub {
    my ( $e, $occurrence ) = booking();
    $e->end( $studio, 'refunded', 're_use_1' );
    my $result = record( $e, $occurrence );
    like "@{ $result->{errors} // [] }", qr/not in effect/, 'a refunded entitlement is refused with a message'
        or diag explain $result;
    is_deeply uses($e), [], 'and no use is recorded';

    my ( $lapsed, $lapsed_on ) = booking();
    $studio->query( q{UPDATE entitlements SET in_effect = tstzrange(lower(in_effect), now() - interval '1 hour', '[)')
                       WHERE id = ?}, $lapsed->id );
    ok record( $lapsed, $lapsed_on )->{errors}, 'one whose period has ended is refused';
    is_deeply uses($lapsed), [], 'and no use is recorded';
};

subtest 'use on unheld occurrence refused' => sub {
    my ( $e )     = booking();
    my $elsewhere = occurrence();
    my $result    = record( $e, $elsewhere );
    like "@{ $result->{errors} // [] }", qr/no place/, 'an occurrence it holds no seat in is refused'
        or diag explain $result;
    is_deeply uses($e), [], 'and no use is recorded';
};

subtest 'non attendance use policy refused' => sub {
    my ( $e, $occurrence ) = booking('none');
    my $result = record( $e, $occurrence );
    like "@{ $result->{errors} // [] }", qr/attendance/, 'use policy none is refused' or diag explain $result;
    is_deeply uses($e), [], 'and no use is recorded';
};

subtest 'malformed ids refused' => sub {
    my ( $e, $occurrence ) = booking();
    for my $case (
        [ 'empty entitlement',    { entitlement_id => '',       occurrence_id => $occurrence->id } ],
        [ 'non-UUID entitlement', { entitlement_id => 'nope',   occurrence_id => $occurrence->id } ],
        [ 'missing entitlement',  { occurrence_id  => $occurrence->id } ],
        [ 'list entitlement',     { entitlement_id => [ $e->id ], occurrence_id => $occurrence->id } ],
        [ 'empty occurrence',     { entitlement_id => $e->id, occurrence_id => '' } ],
        [ 'non-UUID occurrence',  { entitlement_id => $e->id, occurrence_id => '1; DROP' } ],
    ) {
        my ( $name, $form ) = @$case;
        my $result = eval { $step->process( $studio, { %$form, user_id => $staff } ) };
        ok $result && @{ $result->{errors} // [] }, "$name is a validation error, not an exception"
            or diag $@ || explain $result;
    }
    is_deeply uses($e), [], 'and no use is recorded';
};

subtest 'concurrent uses record one' => sub {
    my ( $e, $occurrence ) = booking();
    my ( $waited, $result ) = race(
        sub ($adb) { record( $e, $occurrence, $adb ) },
        sub ($bdb) { record( $e, $occurrence, $bdb ) },
    );
    ok $waited, 'the second record waits for the first';
    ok !$result->{errors} && !$result->{died}, 'then is accepted' or diag explain $result;
    is scalar @{ uses($e) }, 1, 'leaving exactly one use';
};

subtest 'use changes no state units or expiry' => sub {
    my ( $e, $occurrence ) = booking();
    my $row = sub { $studio->select( 'entitlements', '*', { id => $e->id } )->hash };
    my $before       = $row->();
    my $units_before = $e->units( $studio, $occurrence->id );
    my $free_before  = $occurrence->free_units($studio);
    ok !record( $e, $occurrence )->{errors}, 'a use is recorded';
    is_deeply $row->(), $before, 'its state, period and payment link are as they were';
    is_deeply $e->units( $studio, $occurrence->id ), $units_before, 'it holds the same units';
    is $occurrence->free_units($studio), $free_before, 'and the occurrence has the same room';
};

subtest 'other tenant entitlement not found' => sub {
    my $other = new_tenant('other_use_house');
    my ( $theirs, $their_occurrence ) = booking( 'optional_attendance', $other );
    my $result = $step->process( $studio,
        { entitlement_id => $theirs->id, occurrence_id => $their_occurrence->id, user_id => $staff } );
    like "@{ $result->{errors} // [] }", qr/not found/i, "another tenant's entitlement is not found here"
        or diag explain $result;
    is_deeply uses( $theirs, $other ), [], 'no use is recorded in its tenant';
    is $studio->select( 'entitlement_uses', 'count(*)', { entitlement_id => $theirs->id } )->array->[0], 0,
        'nor in this one';
};

done_testing;
