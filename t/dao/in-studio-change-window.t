#!/usr/bin/env perl
# ABOUTME: A booking's change window, measured on the wall clock in its location's time zone, through entitlement-change.
# ABOUTME: The window comes from the stamped offer version; targets are the same offer's; refusals hold and charge nothing.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Helpers qw( import_all_workflows );
use Test::Registry::Offers qw( offer_terms );
use Registry::DAO;
use Registry::DAO::Entitlement;
use Registry::DAO::Offer;
use Registry::DAO::OfferVersion;
use Registry::DAO::Payment;
use Registry::DAO::Resource;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowRun;
use Registry::DAO::WorkflowSteps::ChooseChangeTarget;
use Registry::PriceOps::Hold;
use Mojo::JSON ();
use POSIX ();

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
import_all_workflows($dao);

my $ZONE   = 'America/New_York';
my %WINDOW = ( kind => 'window', window_hours => 48, fee_cents => 1000, targets => 'same_offer' );
my $made   = 0;

sub person () {
    return $db->insert( 'users', { username => "icw-p-$$-" . ++$made }, { returning => 'id' } )->hash->{id};
}

# A class whose occurrences start at @at (hours from now, a timestamptz
# literal, or a reference to SQL), each with $capacity seats (default 4) at a location in $ZONE,
# and a published class offer version covering them with change policy
# $change. Returns the version and the occurrences' resources.
sub occurrences ( $change, @at ) {
    my $capacity = ref $at[-1] eq 'HASH' ? pop(@at)->{capacity} : 4;
    my $class = $db->insert( 'projects', { name => 'Class ' . ++$made, slug => "icw-class-$made" },
        { returning => 'id' } )->hash->{id};
    my @resources = map {
        my $room = $db->insert( 'locations', { time_zone => $ZONE, name => 'Room ' . ++$made, slug => "icw-room-$made" },
            { returning => 'id' } )->hash->{id};
        my $event = $db->insert( 'events', {
            project_id => $class, location_id => $room, teacher_id => person(),
            time       => !ref && /\A-?[0-9]+\z/ ? \"now() + interval '$_ hours'" : $_, duration => 90, capacity => $capacity,
        }, { returning => 'id' } )->hash->{id};
        Registry::DAO::Resource->for_occurrence( $db, $event );
    } @at;
    my $version = Registry::DAO::Offer->create( $db, { name => 'Wheel class ' . $made } )
        ->draft( $db, offer_terms( undef, class_project_id => $class, policies => {
            refund => { kind => 'none' }, change => $change, expiry => { kind => 'end_of_occurrence' } } ) )
        ->publish($db);
    return ( $version, @resources );
}

# An entitlement under $version holding $units seats of $resource until it ends.
sub booking ( $version, $resource, $units = 1, $holder = person() ) {
    my ( undef, $ends ) = $resource->occurrence_window($db);
    return Registry::DAO::Entitlement->grant( $db, {
        holder_user_id   => $holder,
        offer_version_id => $version->id,
        payment_plan_id  => 'pay',
        starts_at        => '2020-01-01T00:00:00Z',
        ends_at          => $ends,
        resource_id      => $resource->id,
        units            => $units,
    } );
}

# The real workflow, as imported from workflows/entitlement-change.yml.
my $workflow = Registry::DAO::Workflow->find( $db, { slug => 'entitlement-change' } )
    or BAIL_OUT 'entitlement-change is not imported';
sub step ($slug) { $workflow->get_step( $db, { slug => $slug } ) }
sub reload ($run) { Registry::DAO::WorkflowRun->find( $db, { id => $run->id } ) }

# A run started by $user_id (default the holder) that asked to change
# $entitlement; returns it and choose-target's result.
sub chosen ( $entitlement, $user_id = $entitlement->holder_user_id ) {
    my $run = $workflow->new_run($db);
    $run->update_data( $db, { user => { id => $user_id }, user_id => $user_id, __tenant_slug => 'registry' } );
    my $result = $run->process( $db, step('choose-target'), { entitlement_id => $entitlement->id } );
    return ( $run, $result );
}

sub hold_target ( $run, $resource ) {
    return $run->process( $db, step('hold-target'), { target_occurrence_id => $resource->id } );
}

sub live_holds ($run) {
    my $live = Registry::PriceOps::Hold->live_sql('holds');
    return $db->query( "SELECT * FROM holds WHERE workflow_run_id = ? AND $live", $run->id )->hashes->to_array;
}

sub payments_of ($run) {
    $db->query( q{SELECT * FROM payments WHERE metadata->>'workflow_run_id' = ?}, $run->id )->hashes->to_array;
}

my $refusal = sub { Registry::DAO::WorkflowSteps::ChooseChangeTarget->refusal( $db, @_ ) };

# Two days before each 2027 DST change in $ZONE, and the clock a second later.
my %EVE = ( 'fall-back' => "2027-11-05 10:00 $ZONE", 'spring-forward' => "2027-03-12 10:00 $ZONE" );
sub later ($at) { $db->query( q{SELECT ?::timestamptz + interval '1 second'}, $at )->array->[0] }

# An occurrence $hours on the wall clock after $at, in $ZONE.
sub wall_after ( $at, $hours ) {
    return \"(('$at'::timestamptz AT TIME ZONE '$ZONE') + interval '$hours hours') AT TIME ZONE '$ZONE'";
}

subtest 'change 49 hours before allowed' => sub {
    for my $eve ( sort keys %EVE ) {
        my ( $version, $held ) = occurrences( \%WINDOW, wall_after( $EVE{$eve}, 49 ) );
        is $refusal->( booking( $version, $held ), later( $EVE{$eve} ) ), undef,
            "49 wall hours before, on the eve of $eve, the change is allowed";
    }
    # Through the workflow on the real clock: 72 hours is more than 48 + 1 DST hour on any date.
    my ( $version, $held, $target ) = occurrences( \%WINDOW, 72, 96 );
    my $e = booking( $version, $held );
    my ( $run, $chose ) = chosen($e);
    ok !$chose->{errors}, 'choosing a target outside the window is allowed' or diag explain $chose->{errors};
    is_deeply [ map { $_->{id} } $chose->{change_targets}->@* ], [ $target->id ], 'the other occurrence is listed';
    my $held_data = hold_target( $run, $target );
    ok !$held_data->{errors}, 'and its seats are held' or diag explain $held_data->{errors};
    is scalar live_holds($run)->@*, 1, 'one live hold for the run';
};

subtest 'change 47 hours before refused with the policy wording' => sub {
    for my $eve ( sort keys %EVE ) {
        my ( $version, $held ) = occurrences( \%WINDOW, wall_after( $EVE{$eve}, 47 ) );
        is $refusal->( booking( $version, $held ), later( $EVE{$eve} ) ), 'Changes close 48 hours before the class starts',
            "47 wall hours before, on the eve of $eve, the change is refused in the policy's words";
    }
    # Through the workflow on the real clock: 24 hours is inside 48 - 1 DST hour on any date.
    my ( $version, $held, $target ) = occurrences( \%WINDOW, 24, 96 );
    my $e = booking( $version, $held );
    my ( $run, $chose ) = chosen($e);
    is_deeply $chose->{errors}, ['Changes close 48 hours before the class starts'],
        'choosing inside the window is refused in the policy\'s words';
    $run->update_data( $db, { change_entitlement_id => $e->id } );    # as if chosen while open
    like "@{ hold_target( $run, $target )->{errors} // [] }", qr/48 hours/, 'and so is holding a target';
    is_deeply live_holds($run), [], 'no hold is placed';
};

# The design's convention: the cutoff is the occurrence's local start minus
# window_hours on the wall clock in the location's zone, inclusive (ADR 005 8b).
subtest 'cutoff is the local wall time 48 hours earlier across March DST' => sub {
    # 10:00 EDT on 2027-03-14, the spring-forward Sunday, is 14:00Z. The wall
    # clock reads 10:00 EST on Friday the 12th, 15:00Z, 47 elapsed hours earlier.
    my ( $version, $held ) = occurrences( \%WINDOW, "2027-03-14 10:00 $ZONE" );
    my $e = booking( $version, $held );
    is $refusal->( $e, '2027-03-12T15:00:00Z' ), undef, 'at 10:00 local on Friday the change is allowed';
    is $refusal->( $e, '2027-03-12T14:30:00Z' ), undef, 'and so it is at 09:30 local, past 48 elapsed hours';
    is $refusal->( $e, '2027-03-12T15:00:01Z' ), 'Changes close 48 hours before the class starts',
        'a second after 10:00 local on Friday it is refused';
};

subtest 'cutoff on a nonexistent local time moves forward by the gap' => sub {
    # 02:30 EDT on Tuesday 2027-03-16 (06:30Z): 48 wall hours earlier is 02:30
    # on the spring-forward Sunday, which never happens; it is read as 03:30 EDT.
    my ( $version, $held ) = occurrences( \%WINDOW, "2027-03-16 02:30 $ZONE" );
    my $e = booking( $version, $held );
    is $refusal->( $e, '2027-03-14T07:30:00Z' ), undef, 'at 03:30 EDT on the Sunday the change is allowed';
    ok $refusal->( $e, '2027-03-14T07:30:01Z' ), 'a second later it is refused';
};

subtest 'cutoff on a repeated local time is the earlier instant' => sub {
    # 01:30 EST on Tuesday 2027-11-09 (06:30Z): 48 wall hours earlier is 01:30
    # on the fall-back Sunday, which happens twice. The cutoff is the first,
    # 01:30 EDT (05:30Z), the stricter reading for the booker.
    my ( $version, $held ) = occurrences( \%WINDOW, "2027-11-09 01:30 $ZONE" );
    my $e = booking( $version, $held );
    is $refusal->( $e, '2027-11-07T05:30:00Z' ), undef, 'at the first 01:30 the change is allowed';
    is $refusal->( $e, '2027-11-07T05:30:01Z' ), 'Changes close 48 hours before the class starts',
        'a second later it is refused, though the second 01:30 is an hour away';
};

subtest 'target of a different offer refused' => sub {
    my ( $version, $held ) = occurrences( \%WINDOW, 72 );
    my ( undef, $elsewhere ) = occurrences( \%WINDOW, 96 );
    my $e = booking( $version, $held );
    my ( $run, $chose ) = chosen($e);
    is_deeply $chose->{change_targets}, [], 'another offer\'s occurrence is not listed';
    ok hold_target( $run, $elsewhere )->{errors}, 'and posting it directly is refused';
    is_deeply live_holds($run), [], 'no hold is placed';
    is $elsewhere->free_units($db), 4, 'the other offer keeps every seat';
};

# Negative scenarios. The issue's `change at exactly the window refused` is
# `... allowed` per the approved design's G7 (ADR 005 8b: inclusive).
subtest 'change at exactly the window allowed' => sub {
    # 10:00 EDT on Thursday 2027-06-10; 48 wall hours earlier is 10:00 EDT, 14:00Z, on the 8th.
    my ( $version, $held ) = occurrences( \%WINDOW, "2027-06-10 10:00 $ZONE" );
    my $e = booking( $version, $held );
    is $refusal->( $e, '2027-06-08T14:00:00Z' ), undef, 'exactly 48 hours before, the change is allowed';
    ok $refusal->( $e, '2027-06-08T14:00:00.000001Z' ), 'any later, it is refused';
};

subtest 'later offer version does not change stamped window' => sub {
    my ( $version, $held, $target ) = occurrences( \%WINDOW, 30, 96 );
    my $e   = booking( $version, $held );
    my $now = Registry::DAO::OfferVersion->draft( $db, $version->offer_id, offer_terms( undef,
        class_project_id => $db->select( 'offer_versions', 'class_project_id', { id => $version->id } )->array->[0],
        policies         => { refund => { kind => 'none' }, change => { %WINDOW, window_hours => 24 },
                              expiry => { kind => 'end_of_occurrence' } } ) )->publish($db);
    is $now->policies->{change}{window_hours}, 24, 'the current version has a 24-hour window';
    my ( $run, $chose ) = chosen($e);
    is_deeply $chose->{errors}, ['Changes close 48 hours before the class starts'],
        '30 hours before, a booking sold under the 48-hour version is still refused';
    $run->update_data( $db, { change_entitlement_id => $e->id } );
    ok hold_target( $run, $target )->{errors}, 'and refused a hold';
    is_deeply live_holds($run), [], 'no hold is placed';
    is $refusal->( booking( $now, $held ), undef ), undef, 'while one sold under the 24-hour version may change';
};

subtest 'full target refused without fee' => sub {
    my ( $version, $held, $target ) = occurrences( \%WINDOW, 72, 96, { capacity => 1 } );
    my $e = booking( $version, $held );
    booking( $version, $target );
    my ( $run, $chose ) = chosen($e);
    is_deeply $chose->{change_targets}, [], 'a full occurrence is not listed';
    ok hold_target( $run, $target )->{errors}, 'and holding it is refused';
    is_deeply live_holds($run), [], 'no hold is placed';
    my $data = reload($run)->data;
    ok !$data->{owed_payment} && !$data->{change_hold}, 'the run owes no fee';
    like $run->process( $db, step('pay'), {} )->{redirect}, qr{/entitlement-change/[^/]+/hold-target\z},
        'so the pay step charges nothing: it sends the person back to choose a target';
    is_deeply payments_of($run), [], 'and no payment is started';
    is_deeply $e->units( $db, $held->id ), [1], 'the entitlement stays where it was';
};

subtest 'failed change fee releases target and keeps original' => sub {
    my ( $version, $held, $target ) = occurrences( \%WINDOW, 72, 96 );
    my $e   = booking( $version, $held );
    my ($run) = chosen($e);
    ok !hold_target( $run, $target )->{errors}, 'the target is held first';
    $run = reload($run);

    # The fee payment the pay step starts, declined as a decline records it.
    my $payment = Registry::DAO::Payment->create( $db, {
        user_id          => $e->holder_user_id,
        amount_cents     => 1000,
        offer_version_id => $version->id,
        metadata         => { workflow_id => $workflow->id, workflow_run_id => $run->id, tenant_slug => 'registry',
                              payment_plan_id => 'pay', description => 'Change fee', purpose => 'change_fee' },
    } );
    $payment->_record_intent( $db, { id => 'pi_icw_' . $payment->id, client_secret => 'x_secret' } );
    $run->update_data( $db, { owed_payment_id => $payment->id } );
    $payment->_record_intent_failure_write( $db, 'Your card was declined.' );

    ok $run->process( $db, step('complete-change'), {} )->{errors}, 'a declined fee does not complete the change';
    # The hold's lifetime runs out, as the clock would make it, and it is let go.
    $db->query( q{UPDATE holds SET expires_at = clock_timestamp() - interval '1 second' WHERE workflow_run_id = ?},
        $run->id );
    is_deeply live_holds($run), [], 'the target hold is released';
    is $target->free_units($db), 4, 'so the target has every seat';
    ok $run->process( $db, step('complete-change'), {} )->{errors}, 'and the change still does not complete';
    is_deeply $e->units( $db, $held->id ), [1], 'the entitlement keeps its seat';
    ok Registry::DAO::Entitlement->in_effect_at( $db, $db->query('SELECT now()')->array->[0], { id => $e->id } ), 'and stays in effect';
};

subtest 'past or same target refused' => sub {
    my ( $version, $held, $started ) = occurrences( \%WINDOW, 72, -1 );
    my $e = booking( $version, $held );
    my ( $run, $chose ) = chosen($e);
    is_deeply $chose->{change_targets}, [], 'neither its own occurrence nor one under way is listed';
    ok hold_target( $run, $started )->{errors}, 'a target that has started is refused';
    ok hold_target( $run, $held )->{errors}, 'and so is its own occurrence';
    is_deeply live_holds($run), [], 'no hold is placed';
};

subtest 'another customers booking cannot be changed' => sub {
    my ( $version, $held, $target ) = occurrences( \%WINDOW, 72, 96 );
    my $e = booking( $version, $held );
    my ( $run, $chose ) = chosen( $e, person() );
    like "@{ $chose->{errors} // [] }", qr/not yours to change/, 'another customer is refused the change';
    $run->update_data( $db, { change_entitlement_id => $e->id } );    # as if posted to the run's URL
    like "@{ hold_target( $run, $target )->{errors} // [] }", qr/not yours/, 'and refused a hold';
    is_deeply live_holds($run), [], 'no hold is placed';
};

subtest 'ended entitlement cannot be changed' => sub {
    my ( $version, $held, $target ) = occurrences( \%WINDOW, 72, 96 );
    for my $state (qw( refunded expired )) {
        my $e = booking( $version, $held )->end( $db, $state, "test: $state" );
        my ( $run, $chose ) = chosen($e);
        like "@{ $chose->{errors} // [] }", qr/ended/, "a $state booking is refused a change";
        $run->update_data( $db, { change_entitlement_id => $e->id } );
        ok hold_target( $run, $target )->{errors}, 'and refused a hold';
        is_deeply live_holds($run), [], 'no hold is placed';
    }
};

# Two connections: A, in a transaction, runs $first; B, a child process,
# runs $second, which must wait on A's lock. Once B waits, A commits.
# Returns whether B waited and what $second returned.
sub race ( $first, $second ) {
    my $uri = $test_db->uri;
    pipe( my $parent_reads, my $child_writes ) or die "pipe: $!";
    my $adb = Registry::DAO->new( url => $uri )->db;
    my $tx  = $adb->begin;
    my $a   = $first->($adb);
    my $holder = $adb->query('SELECT pg_backend_pid()')->array->[0];
    my $pid    = fork() // die "fork: $!";
    unless ($pid) {
        close $parent_reads;
        my $bdb = Registry::DAO->new( url => $uri )->db;
        my $out = eval { Mojo::JSON::to_json( $second->($bdb) ) } // Mojo::JSON::to_json( { died => "$@" } );
        print $child_writes $out;
        close $child_writes;
        POSIX::_exit(0);
    }
    close $child_writes;
    my ( $blocked, $deadline ) = ( 0, time + 30 );
    until ( $blocked || waitpid( $pid, POSIX::WNOHANG() ) || time > $deadline ) {
        select undef, undef, undef, 0.05;
        $blocked = $db->query( 'SELECT count(*) FROM pg_stat_activity WHERE ? = ANY (pg_blocking_pids(pid))',
            $holder )->array->[0];
    }
    $tx->commit;
    waitpid $pid, 0;
    return ( $blocked, $a, Mojo::JSON::from_json( do { local $/; readline $parent_reads } ) );
}

subtest 'concurrent changes into last seat one wins' => sub {
    my ( $version, $held, $target ) = occurrences( \%WINDOW, 72, 96, { capacity => 2 } );
    booking( $version, $target );
    my ($one) = chosen( booking( $version, $held ) );
    my ($two) = chosen( booking( $version, $held ) );
    my ( $waited, $first, $second ) = race(
        sub ($adb) { $one->process( $adb, step('hold-target'), { target_occurrence_id => $target->id } ) },
        sub ($bdb) { $two->process( $bdb, step('hold-target'), { target_occurrence_id => $target->id } ) },
    );
    ok $waited, 'the second change waits on the first one\'s hold of the target';
    ok !$first->{errors}, 'the first change holds the last seat' or diag explain $first->{errors};
    like "@{ $second->{errors} // [] }", qr/room/, 'the second is refused' or diag explain $second;
    is scalar live_holds($one)->@*, 1, 'one hold, the first change\'s';
    is_deeply live_holds($two), [], 'none for the second';
    ok !reload($two)->data->{owed_payment}, 'the second owes no fee';
    like $two->process( $db, step('pay'), {} )->{redirect}, qr{/entitlement-change/[^/]+/hold-target\z},
        'and its pay step charges nothing: it sends the person back to choose a target';
    is_deeply payments_of($two), [], 'no payment is started for it';
    is $target->free_units($db), 0, 'the target is full';
};

done_testing;
