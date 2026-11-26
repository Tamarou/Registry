#!/usr/bin/env perl
# ABOUTME: Every recurring sweep acts on the platform tenant's own data (the registry schema) as on any tenant's.
# ABOUTME: Real Minion on real Postgres: work is planted in registry, each sweep is run, and its effect and report are read.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use experimental qw(signatures);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Mojo;
use DateTime;
use Email::Sender::Simple;
use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::Location;
use Registry::DAO::Project;
use Registry::DAO::Session;
use Registry::DAO::Event;
use Registry::DAO::Enrollment;
use Registry::DAO::Waitlist;
use Registry::DAO::Notification;
use Registry::DAO::UserPreference;

my $test_db = Test::Registry::DB->new;
my $db      = $test_db->db->db;    # the registry schema: the platform tenant's own
my $t       = Test::Registry::Mojo->new('Registry');
my $app     = $t->app;
my $minion  = $app->minion;

$app->log->level('fatal');
$app->import_workflows;    # attendance_check runs the attendance-check workflow

# The sweeps that walk the tenant list and report what they covered.
my @PER_TENANT = qw( attendance_check expire_entitlements instalment_reconcile process_waitlist
                     send_notifications waitlist_expiration );

# The platform's row names its own Stripe account, as every tenant's does.
$db->query( q{UPDATE registry.tenants SET stripe_connect_account_id = 'acct_platform_sweeps'
               WHERE slug = 'registry'} );
my $platform_id = $db->query(q{SELECT id FROM registry.tenants WHERE slug = 'registry'})->hash->{id};

my $n = 0;
sub user ( $type, %extra ) {
    $n++;
    my $user = Registry::DAO::User->create( $db, {
        username => "sweep_${type}_${n}_$$", name => "Sweep \u$type $n",
        email => "sweep_${type}_${n}_$$\@test.example", user_type => $type, %extra } );
    return $user;
}

sub session_with ( %args ) {
    $n++;
    return Registry::DAO::Session->create( $db, {
        name => "Sweep Session $n", slug => "sweep-session-$n-$$", %args } );
}

my $location = Registry::DAO::Location->create( $db, { time_zone => 'America/New_York',
    name => "Sweep Location $$", slug => "sweep-location-$$", address_info => { street => '1 Sweep St' } } );
my $project = Registry::DAO::Project->create( $db, {
    name => "Sweep Project $$", slug => "sweep-project-$$" } );

# Runs $task once through Minion's own worker and returns the finished job's info.
sub run_sweep ($task) {
    my $id = $minion->enqueue($task);
    $minion->perform_jobs_in_foreground( { id => $id } );
    return $minion->job($id)->info;
}

sub covered ($info) { $info->{result} && ref $info->{result} eq 'HASH' ? $info->{result}{tenants_covered} // [] : [] }
sub skipped ($info) { [ map { $_->{slug} } @{ ref $info->{result} eq 'HASH' ? $info->{result}{tenants_skipped} // [] : [] } ] }
sub count_of ( $slug, $list ) { scalar grep { $_ eq $slug } @$list }

# ---- work planted in registry, one kind per sweep ---------------------------

sub plant_expired_offer () {
    my ( $parent, $student ) = ( user('parent'), user('student') );
    my $session = session_with( capacity => 1 );
    return $db->query( q{
        INSERT INTO waitlist (session_id, location_id, student_id, parent_id, position, status, offered_at, expires_at)
        VALUES (?, ?, ?, ?, 1, 'offered', now() - interval '49 hours', now() - interval '1 hour')
        RETURNING id
    }, $session->id, $location->id, $student->id, $parent->id )->hash->{id};
}

sub plant_freed_seat () {
    my ( $parent, $student, $leaver ) = ( user('parent'), user('student'), user('student') );
    my $session = session_with( capacity => 1 );
    Registry::DAO::Enrollment->create( $db, {
        session_id => $session->id, student_id => $leaver->id, parent_id => $parent->id, status => 'cancelled' } );
    return Registry::DAO::Waitlist->create( $db, {
        session_id => $session->id, location_id => $location->id, student_id => $student->id,
        parent_id => $parent->id, position => 1, status => 'waiting' } )->id;
}

sub plant_queued_email () {
    my $parent = user('parent');
    $db->insert( 'user_profiles', { user_id => $parent->id, email => $parent->email, name => 'Sweep Parent' },
        { on_conflict => undef } );
    my $note = Registry::DAO::Notification->create( $db, {
        user_id => $parent->id, type => 'enrollment_confirmation', channel => 'email',
        subject => 'Queued for the sweep', message => 'Sent by send_notifications.' } );
    return ( $note->id, $parent->email );
}

sub plant_unmarked_event () {
    my $teacher = user('staff');
    $db->insert( 'user_profiles', { user_id => $teacher->id, email => $teacher->email, name => 'Sweep Teacher' },
        { on_conflict => undef } );
    Registry::DAO::UserPreference->update_notification_preferences( $db, $teacher->id, {
        attendance_missing => { email => 1, in_app => 0 } } );
    my $session = session_with();
    Registry::DAO::Enrollment->create( $db, {
        session_id => $session->id, student_id => user('student')->id, status => 'active' } );
    my $event = Registry::DAO::Event->create( $db, {
        location_id => $location->id, project_id => $project->id, teacher_id => $teacher->id,
        start_time => DateTime->now->subtract( minutes => 10 ), end_time => DateTime->now->add( minutes => 50 ),
        metadata => { title => 'Sweep Event' } } );
    $db->insert( 'session_events', { session_id => $session->id, event_id => $event->id } );
    return $event->id;
}

sub plant_overdue_domain () {
    $n++;
    return $db->query( q{
        INSERT INTO tenant_domains (tenant_id, domain, status, render_domain_id, created_at)
        VALUES (?, ?, 'pending', ?, now() - interval '8 days') RETURNING id
    }, $platform_id, "sweep-$n-$$.example.com", "rdm_sweep_$n" )->hash->{id};
}

sub attendance_emails ($event_id) {
    $db->query( q{SELECT count(*) FROM notifications
                   WHERE type = 'attendance_missing' AND channel = 'email' AND metadata->>'event_id' = ?},
        $event_id )->array->[0];
}

sub status_of ( $table, $id ) { $db->query( "SELECT status FROM $table WHERE id = ?", $id )->hash->{status} }

subtest 'every sweep covers registry' => sub {
    my $offer  = plant_expired_offer();
    my $seat   = plant_freed_seat();
    my ($note) = plant_queued_email();
    my $event  = plant_unmarked_event();
    my $domain = plant_overdue_domain();

    my %info = map { $_ => run_sweep($_) } @PER_TENANT, 'domain_verification';
    for my $task ( sort keys %info ) {
        is $info{$task}{state}, 'finished', "$task finished";
    }
    for my $task (@PER_TENANT) {
        ok count_of( registry => covered( $info{$task} ) ), "$task reports registry among the tenants covered";
    }

    is status_of( waitlist => $offer ), 'expired', "waitlist_expiration expired registry's lapsed offer";
    is status_of( waitlist => $seat ),  'offered', "process_waitlist offered registry's freed seat";
    ok $db->query( 'SELECT sent_at FROM notifications WHERE id = ?', $note )->hash->{sent_at},
        "send_notifications sent registry's queued email";
    is attendance_emails($event), 1, "attendance_check told registry's teacher about the unmarked register";
    is status_of( tenant_domains => $domain ), 'failed', "domain_verification closed registry's overdue domain";
};

# ---- the fleet beside registry: one sound tenant, one broken, one with no schema

my $ok_slug     = "sweep_ok_$$";
my $broken_slug = "sweep_broken_$$";
my $ghost_slug  = "sweep_ghost_$$";

Registry::DAO::Tenant->provision( $db, { name => "Sweep OK $$", slug => $ok_slug, users => [ user('admin') ],
    stripe_connect_account_id => 'acct_sweep_ok' } );
Registry::DAO::Tenant->provision( $db, { name => "Sweep Broken $$", slug => $broken_slug, users => [ user('admin') ],
    stripe_connect_account_id => 'acct_sweep_broken' } );

# A real failure in one tenant's schema: every table a sweep reads is renamed away.
$db->query(qq{ALTER TABLE "$broken_slug".$_ RENAME TO ${_}_gone})
    for qw( waitlist enrollments notifications events payments entitlements );

# A tenant row whose schema was never made.
$db->insert( 'registry.tenants', { name => "Sweep Ghost $$", slug => $ghost_slug,
    stripe_connect_account_id => 'acct_sweep_ghost' } );

subtest 'failing tenant does not stop the sweep' => sub {
    for my $task (@PER_TENANT) {
        my $info = run_sweep($task);
        is $info->{state}, 'finished', "$task finished";
        ok count_of( registry => covered($info) ), "$task covered registry";
        ok count_of( $ok_slug => covered($info) ), "$task covered the sound tenant";
        ok count_of( $broken_slug => skipped($info) ), "$task reported the broken tenant";
        ok !count_of( $broken_slug => covered($info) ), "$task did not claim the broken tenant as covered";
    }
};

subtest 'registry covered exactly once' => sub {
    Email::Sender::Simple->default_transport->clear_deliveries;
    my ( $note, $address ) = plant_queued_email();
    my $event = plant_unmarked_event();

    my %info = map { $_ => run_sweep($_) } @PER_TENANT;
    for my $task (@PER_TENANT) {
        is count_of( registry => covered( $info{$task} ) ), 1, "$task covered registry once";
    }

    my @to_address = grep { grep { $_ eq $address } @{ $_->{successes} } }
        Email::Sender::Simple->default_transport->deliveries;
    is scalar @to_address, 1, "registry's queued email was sent once";
    is attendance_emails($event), 1, "registry's teacher was told once about the unmarked register";
};

subtest 'missing tenant schema reported as failure' => sub {
    for my $task (@PER_TENANT) {
        my $info = run_sweep($task);
        is $info->{state}, 'finished', "$task finished";
        ok count_of( $ghost_slug => skipped($info) ), "$task reported the tenant with no schema";
        ok !count_of( $ghost_slug => covered($info) ), "$task did not claim it as covered";
        ok count_of( registry => covered($info) ), "$task still covered registry";
    }
};

done_testing;
