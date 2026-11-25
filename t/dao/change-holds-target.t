#!/usr/bin/env perl
# ABOUTME: A change checks the entitlement's stamped change policy, lists same-offer targets and holds the target's seats.
# ABOUTME: Drives ChooseChangeTarget and HoldChangeTarget through a real workflow run in a tenant schema.
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
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::PriceOps::Hold;
use POSIX ();
use Mojo::JSON ();
use Registry::DAO::WorkflowRun;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $SLUG = 'change_house';
Registry::DAO::Tenant->create( $db, { name => 'Change House', slug => $SLUG } );
$db->query( 'SELECT clone_schema(dest_schema => ?)', $SLUG );
my $studio = Registry::DAO->new( url => $dao->url, schema => $SLUG )->db;

my %WINDOW = ( kind => 'window', window_hours => 48, fee_cents => 1000, targets => 'same_offer' );
my $made   = 0;

sub person () {
    return $studio->insert( 'users', { username => 'p-' . ++$made }, { returning => 'id' } )->hash->{id};
}

# A class whose occurrences start $hours from now, each with $capacity seats
# and its own resource, and a published class offer version covering them
# with change policy $change. Returns the version and the resources.
sub occurrences ( $change, @hours ) {
    my $capacity = ref $hours[-1] ? pop(@hours)->{capacity} : 4;
    my $class = $studio->insert( 'projects', { name => 'Class ' . ++$made, slug => "class-$made" },
        { returning => 'id' } )->hash->{id};
    my @resources = map {
        my $room = $studio->insert( 'locations', { name => 'Room ' . ++$made, slug => "room-$made" },
            { returning => 'id' } )->hash->{id};
        my $event = $studio->insert( 'events', {
            project_id => $class, location_id => $room, teacher_id => person(),
            time       => \"now() + interval '$_ hours'", duration => 90, capacity => $capacity,
        }, { returning => 'id' } )->hash->{id};
        Registry::DAO::Resource->for_occurrence( $studio, $event );
    } @hours;
    my $version = Registry::DAO::Offer->create( $studio, { name => 'Wheel class ' . $made } )
        ->draft( $studio, offer_terms( undef, class_project_id => $class,
            policies => { refund => { kind => 'none' }, change => $change } ) )->publish($studio);
    return ( $version, @resources );
}

# An entitlement under $version holding $units seats of $resource.
sub booking ( $version, $resource, $units = 1, %more ) {
    return Registry::DAO::Entitlement->grant( $studio, {
        holder_user_id   => person(),
        offer_version_id => $version->id,
        payment_plan_id  => 'pay',
        starts_at        => '2020-01-01T00:00:00Z',
        resource_id      => $resource->id,
        units            => $units,
        %more,
    } );
}

my $workflow = Registry::DAO::Workflow->create( $studio,
    { slug => 'change-test', name => 'Change test', description => 'change steps under test' } );
my $choose = Registry::DAO::WorkflowStep->create( $studio, {
    workflow_id => $workflow->id, slug => 'choose-target',
    class       => 'Registry::DAO::WorkflowSteps::ChooseChangeTarget', description => 'choose',
} );
my $hold_step = Registry::DAO::WorkflowStep->create( $studio, {
    workflow_id => $workflow->id, slug => 'hold-target',
    class       => 'Registry::DAO::WorkflowSteps::HoldChangeTarget', description => 'hold',
    depends_on  => $choose->id,
} );
$_ = Registry::DAO::WorkflowStep->find( $studio, { id => $_->id } ) for $choose, $hold_step;

# A run in which $entitlement's holder, signed in as the controller records
# it, chose to change it; returns it and ChooseChangeTarget's result.
sub chosen ($entitlement) {
    my $run    = $workflow->new_run($studio);
    $run->update_data( $studio, { user => { id => $entitlement->holder_user_id } } );
    my $result = $run->process( $studio, $choose, { entitlement_id => $entitlement->id } );
    return ( $run, $result );
}

sub hold_target ( $run, $resource, %more ) {
    return $run->process( $studio, $hold_step, { target_occurrence_id => $resource->id, %more } );
}

sub live_holds ($run) {
    my $live = Registry::PriceOps::Hold->live_sql('holds');
    return $studio->query( "SELECT * FROM holds WHERE workflow_run_id = ? AND $live", $run->id )->hashes->to_array;
}

subtest 'change lists same offer and holds target' => sub {
    my ( $version, $held, $target ) = occurrences( \%WINDOW, 72, 96 );
    my ( undef, $elsewhere ) = occurrences( \%WINDOW, 96 );
    my $e = booking( $version, $held, 2 );

    my ( $run, $chose ) = chosen($e);
    ok !$chose->{errors}, 'the change is allowed' or diag explain $chose->{errors};
    is_deeply [ map { $_->{id} } $chose->{change_targets}->@* ], [ $target->id ],
        'it lists the other occurrence of the same offer, not its own nor another offer\'s';

    my $data = hold_target( $run, $target );
    ok !$data->{errors}, 'the hold step accepts it' or diag explain $data->{errors};
    my $holds = live_holds($run);
    is scalar @$holds, 1, 'one live hold is placed for the run';
    is $holds->[0]{resource_id}, $target->id, 'on the target';
    is $holds->[0]{units}, 2, "for the entitlement's seat count";
    is $target->free_units($studio), 2, 'so the target has two of four seats free';
    is_deeply $e->units( $studio, $held->id ), [ 1, 2 ], 'the entitlement is not moved yet';
    is_deeply $data->{change_hold}, {
        entitlement_id       => $e->id,
        target_occurrence_id => $target->id,
        hold_id              => $holds->[0]{id},
        fee_cents            => 1000,
        offer_version_id     => $version->id,
    }, 'and the run carries the change with the stamped fee';
};

subtest 'change inside the window refused' => sub {
    my ( $version, $held, $target ) = occurrences( \%WINDOW, 24, 96 );
    my $e = booking( $version, $held );
    my ( $run, $chose ) = chosen($e);
    like "@{ $chose->{errors} // [] }", qr/48 hours/, 'choosing a target 24h before a 48h window is refused';
    my $data = hold_target( $run, $target );
    ok $data->{errors}, 'and so is holding one';
    is_deeply live_holds($run), [], 'no hold is placed';
    is $target->free_units($studio), 4, 'the target keeps every seat';
};

subtest 'policy allowing no change refused' => sub {
    for my $change ( { kind => 'none' }, undef ) {
        my ( $version, $held, $target ) = $change ? occurrences( $change, 72, 96 ) : do {
            my ( $v, @r ) = occurrences( \%WINDOW, 72, 96 );
            # A version stamped with no change policy at all, as one published before change existed.
            my $none = Registry::DAO::Offer->create( $studio, { name => 'No change ' . ++$made } )
                ->draft( $studio, offer_terms( undef, class_project_id => $studio->select(
                    'offer_versions', 'class_project_id', { id => $v->id } )->array->[0] ) )->publish($studio);
            ( $none, @r );
        };
        my $e = booking( $version, $held );
        my ( $run, $chose ) = chosen($e);
        like "@{ $chose->{errors} // [] }", qr/cannot be changed/,
            'a change under ' . ( $change ? 'a none' : 'no' ) . ' change policy is refused';
        ok hold_target( $run, $target )->{errors}, 'and so is holding a target';
        is_deeply live_holds($run), [], 'no hold is placed';
    }
};

subtest 'insufficient seats refused with no partial hold' => sub {
    my ( $version, $held, $target ) = occurrences( \%WINDOW, 72, 96, { capacity => 2 } );
    my $e = booking( $version, $held, 2 );
    booking( $version, $target, 1 );
    my ( $run, $chose ) = chosen($e);
    is_deeply $chose->{change_targets}, [], 'a target with one free seat is not listed for two';
    ok hold_target( $run, $target )->{errors}, 'and holding it is refused';
    is_deeply live_holds($run), [], 'no hold, partial or whole, is left behind';
    is $target->free_units($studio), 1, 'the free seat stays free';
};

subtest 'fee comes from stamped offer version' => sub {
    my ( $version, $held, $target ) = occurrences( \%WINDOW, 72, 96 );
    my $e = booking( $version, $held );
    my $offer_id = $version->offer_id;
    my $class    = $studio->select( 'offer_versions', 'class_project_id', { id => $version->id } )->array->[0];
    my $current  = Registry::DAO::OfferVersion->draft( $studio, $offer_id, offer_terms( undef,
        class_project_id => $class,
        policies         => { refund => { kind => 'none' }, change => { %WINDOW, fee_cents => 2500 } } ) )
        ->publish($studio);

    my ($run) = chosen($e);
    my $data = hold_target( $run, $target );
    is $data->{change_hold}{fee_cents}, 1000, 'the fee is the one the entitlement was sold under, not 2500';
    is $data->{change_hold}{offer_version_id}, $version->id, 'and the version named is the stamped one';
    isnt $current->id, $version->id, 'though a newer version is current';
};

# Two real connections. A opens a transaction and runs $first, which takes a
# lock; B (a child process, its own connection) runs $second, which must wait
# on that lock. Once pg_blocking_pids shows B waiting, A commits. Returns
# whether B waited and what $second returned, as JSON.
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

subtest 'own occurrence refused as target' => sub {
    my ( $version, $held, $target ) = occurrences( \%WINDOW, 72, 96 );
    my $e = booking( $version, $held );
    my ($run) = chosen($e);
    ok hold_target( $run, $held )->{errors}, "the entitlement's own occurrence is refused";
    is_deeply live_holds($run), [], 'no hold is placed';
    is $held->free_units($studio), 3, 'its occurrence has only its own seat taken';
};

subtest 'started target refused' => sub {
    my ( $version, $held, $started, $ended ) = occurrences( \%WINDOW, 72, -1, -48 );
    my $e = booking( $version, $held );
    my ( $run, $chose ) = chosen($e);
    is_deeply $chose->{change_targets}, [], 'an occurrence under way or over is not listed';
    for ( [ $started, 'under way' ], [ $ended, 'over' ] ) {
        my ( $target, $what ) = @$_;
        ok hold_target( $run, $target )->{errors}, "a target $what is refused";
    }
    is_deeply live_holds($run), [], 'no hold is placed';
};

subtest 'other offer target refused' => sub {
    my ( $version, $held ) = occurrences( \%WINDOW, 72 );
    my ( undef, $elsewhere ) = occurrences( \%WINDOW, 96 );
    my $e = booking( $version, $held );
    my ($run) = chosen($e);
    ok hold_target( $run, $elsewhere )->{errors}, "another offer's occurrence posted directly is refused";
    ok $run->process( $studio, $hold_step, { target_occurrence_id => 'not-a-uuid' } )->{errors},
        'and so is something that is no occurrence';
    is_deeply live_holds($run), [], 'no hold is placed';
    is $elsewhere->free_units($studio), 4, 'the other offer keeps every seat';
};

subtest 'ended entitlement refused change' => sub {
    my ( $version, $held, $target ) = occurrences( \%WINDOW, 72, 96 );
    my $expired = booking( $version, $held );
    $expired->end( $studio, 'expired', 'occurrence ended' );
    my $over = booking( $version, $held, 1, ends_at => '2021-01-01T00:00:00Z' );
    for ( [ $expired, 'an expired' ], [ $over, 'an active one whose period ended' ] ) {
        my ( $e, $what ) = @$_;
        my ( $run, $chose ) = chosen($e);
        like "@{ $chose->{errors} // [] }", qr/ended/, "$what entitlement is refused a change";
        $run->update_data( $studio, { change_entitlement_id => $e->id } );    # as if chosen while current
        ok hold_target( $run, $target )->{errors}, 'and refused a hold';
        is_deeply live_holds($run), [], 'no hold is placed';
    }
};

subtest 'window closing between steps refused' => sub {
    my ( $version, $held, $target ) = occurrences( \%WINDOW, 72, 96 );
    my $e = booking( $version, $held );
    my ( $run, $chose ) = chosen($e);
    ok !$chose->{errors}, 'the change is allowed when chosen';
    $studio->query( q{UPDATE events SET time = now() + interval '47 hours 59 minutes'
                       WHERE id = ?}, $held->event_id );
    like "@{ hold_target( $run, $target )->{errors} // [] }", qr/48 hours/,
        'once the window closes the hold step refuses';
    is_deeply live_holds($run), [], 'no hold is left behind';
    is $target->free_units($studio), 4, 'the target keeps every seat';
};

subtest 'client change data ignored' => sub {
    my ( $version, $held, $target ) = occurrences( \%WINDOW, 72, 96 );
    my ( $other, $elsewhere ) = occurrences( \%WINDOW, 96 );
    my $e = booking( $version, $held );
    my $stranger = booking( $other, $elsewhere );
    my ($run) = chosen($e);
    my $data = hold_target( $run, $target,
        fee_cents => 1, hold_id => 'forged', offer_version_id => $other->id, entitlement_id => $stranger->id,
        change    => { fee_cents => 1, hold_id => 'forged', offer_version_id => $other->id } );
    my $holds = live_holds($run);
    is_deeply $data->{change_hold}, {
        entitlement_id       => $e->id,
        target_occurrence_id => $target->id,
        hold_id              => $holds->[0]{id},
        fee_cents            => 1000,
        offer_version_id     => $version->id,
    }, 'the change comes from the stamped policy and the placed hold only';
    is_deeply Registry::DAO::WorkflowRun->find( $studio, { id => $run->id } )->data->{change_hold}, $data->{change_hold},
        'and that is what the run stores';
};

subtest 'double hold submit leaves one hold' => sub {
    my ( $version, $held, $first, $second ) = occurrences( \%WINDOW, 72, 96, 120 );
    my $e = booking( $version, $held, 2 );
    my ($run) = chosen($e);
    hold_target( $run, $first );
    my $data = hold_target( $run, $first );
    my $holds = live_holds($run);
    is scalar @$holds, 1, 'submitting the same target twice leaves one live hold';
    is $data->{change_hold}{hold_id}, $holds->[0]{id}, 'and the run names it';
    is $first->free_units($studio), 2, 'holding two seats, not four';

    $data  = hold_target( $run, $second );
    $holds = live_holds($run);
    is scalar @$holds, 1, 'choosing another target leaves one live hold';
    is $holds->[0]{resource_id}, $second->id, 'on the new target';
    is $first->free_units($studio), 4, 'the first target gets its seats back';

    my ( $waited, $result ) = race(
        sub ($adb) { $run->process( $adb, $hold_step, { target_occurrence_id => $first->id } ) },
        sub ($bdb) { $run->process( $bdb, $hold_step, { target_occurrence_id => $first->id } ) },
    );
    ok $waited, 'a concurrent submit for the same run waits for the first';
    ok !$result->{errors} && !$result->{died}, 'then goes through' or diag explain $result;
    $holds = live_holds($run);
    is scalar @$holds, 1, 'leaving one live hold';
    is $result->{change_hold}{hold_id}, $holds->[0]{id}, 'the one the second submit names';
    is Registry::DAO::WorkflowRun->find( $studio, { id => $run->id } )->data->{change_hold}{hold_id}, $holds->[0]{id},
        'and the one the run stores';
    is $first->free_units($studio) + $second->free_units($studio), 6, 'two seats held in all';
};

subtest 'last seat taken while holding refused' => sub {
    my ( $version, $held, $target ) = occurrences( \%WINDOW, 72, 96, { capacity => 1 } );
    my $e = booking( $version, $held );
    my ($run) = chosen($e);
    my $other_run = $workflow->new_run($studio);
    my ( $waited, $result ) = race(
        sub ($adb) {
            Registry::PriceOps::Hold->place( $adb, { resource_id => $target->id, units => 1,
                workflow_run_id => $other_run->id, expires_at => \"now() + interval '15 minutes'" } );
        },
        sub ($bdb) { $run->process( $bdb, $hold_step, { target_occurrence_id => $target->id } ) },
    );
    ok $waited, 'the hold step waits on the target another transaction is holding';
    like "@{ $result->{errors} // [] }", qr/room/, 'then refuses: the seat is gone'
        or diag explain $result;
    is_deeply live_holds($run), [], 'no hold is left behind';
};

subtest '2-seat entitlement moves to the held target in one transaction' => sub {
    my ( $version, $held, $target ) = occurrences( \%WINDOW, 72, 96 );
    my $e = booking( $version, $held, 2 );
    my ($run) = chosen($e);
    my $hold = Registry::PriceOps::Hold->find( $studio,
        { id => hold_target( $run, $target )->{change_hold}{hold_id} }, 'id' );
    my $tx = $studio->begin;
    $hold->convert( $studio, $e );
    $tx->commit;
    is_deeply $e->units( $studio, $target->id ), [ 1, 2 ], 'both seats move to the target';
    is_deeply $e->units( $studio, $held->id ), [], 'and leave the old occurrence';
    is $held->free_units($studio), 4, 'which is free again';
};

done_testing;
