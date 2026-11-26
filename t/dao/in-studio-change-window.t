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

# A class whose occurrences start at @at (hours from now, or a timestamptz
# literal), each with $capacity seats (default 4) at a location in $ZONE,
# and a published class offer version covering them with change policy
# $change. Returns the version and the occurrences' resources.
sub occurrences ( $change, @at ) {
    my $capacity = ref $at[-1] ? pop(@at)->{capacity} : 4;
    my $class = $db->insert( 'projects', { name => 'Class ' . ++$made, slug => "icw-class-$made" },
        { returning => 'id' } )->hash->{id};
    my @resources = map {
        my $room = $db->insert( 'locations', { time_zone => $ZONE, name => 'Room ' . ++$made, slug => "icw-room-$made" },
            { returning => 'id' } )->hash->{id};
        my $event = $db->insert( 'events', {
            project_id => $class, location_id => $room, teacher_id => person(),
            time       => /\A-?[0-9]+\z/ ? \"now() + interval '$_ hours'" : $_, duration => 90, capacity => $capacity,
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

subtest 'change 49 hours before allowed' => sub {
    my ( $version, $held, $target ) = occurrences( \%WINDOW, 49, 96 );
    my $e = booking( $version, $held );
    my ( $run, $chose ) = chosen($e);
    ok !$chose->{errors}, 'choosing a target 49 hours before is allowed' or diag explain $chose->{errors};
    is_deeply [ map { $_->{id} } $chose->{change_targets}->@* ], [ $target->id ], 'the other occurrence is listed';
    my $held_data = hold_target( $run, $target );
    ok !$held_data->{errors}, 'and its seats are held' or diag explain $held_data->{errors};
    is scalar live_holds($run)->@*, 1, 'one live hold for the run';
};

subtest 'change 47 hours before refused with the policy wording' => sub {
    my ( $version, $held, $target ) = occurrences( \%WINDOW, 47, 96 );
    my $e = booking( $version, $held );
    my ( $run, $chose ) = chosen($e);
    is_deeply $chose->{errors}, ['Changes close 48 hours before the class starts'],
        'choosing 47 hours before a 48-hour window is refused in the policy\'s words';
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

done_testing;
