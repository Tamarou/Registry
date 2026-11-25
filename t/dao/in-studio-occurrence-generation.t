#!/usr/bin/env perl
# ABOUTME: The in-studio-schedule workflow generates a class's occurrences, driven through the real WorkflowProcessor.
# ABOUTME: Each slot is an events row at the studio's local wall time with its own finite resource of the class's seats.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( import_all_workflows join_tenant );
use Test::Registry::Offers qw( offer_terms );
use Registry::DAO;
use Registry::DAO::Event;
use Registry::DAO::Offer;
use Registry::DAO::Project;
use Registry::DAO::Resource;
use Registry::DAO::Workflow;
use Registry::Utility::WorkflowProcessor;
use Registry::WorkflowStepClasses;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

my $SLUG = 'clay_studio';
import_all_workflows($dao);
Test::Registry::Fixtures::create_tenant( $dao, { name => 'Clay Studio', slug => $SLUG } );
my $tenant_dao = Registry::DAO->new( url => $test_db->uri, schema => $SLUG );
my $tdb        = $tenant_dao->db;
import_all_workflows($tenant_dao);

my %user;
for my $role (qw( admin staff parent )) {
    $user{$role} = Test::Registry::Fixtures::create_user( $dao,
        { username => "clay_$role", name => "Clay \u$role", email => "$role\@clay.test", user_type => $role } );
    join_tenant( $dao, $user{$role}, $role, $SLUG );
    # A teacher must be a user of this schema: events.teacher_id references it.
    $dao->db->query( 'SELECT copy_user(dest_schema => ?, user_id => ?)', $SLUG, $user{$role}->id );
}

my $room  = Test::Registry::Fixtures::create_location( $tdb,
    { name => 'Clay room', slug => 'clay-room', time_zone => 'America/New_York' } );
my $annex = Test::Registry::Fixtures::create_location( $tdb,
    { name => 'Clay annex', slug => 'clay-annex', time_zone => 'America/New_York' } );

my $workflow = $tenant_dao->find( Workflow => { slug => 'in-studio-schedule' } );

# A fresh class of $seats seats per occurrence at the room.
sub new_class ( $seats = 8 ) {
    state $n = 0;
    ++$n;
    return Registry::DAO::Project->create( $tdb, {
        name => "Throwing $n", seats_per_occurrence => $seats, metadata => { location_id => $room->id },
    } );
}

sub start ( $who = 'admin', $handle = $tenant_dao ) {
    return Registry::WorkflowProcessor->new( dao => $handle )
        ->new_run( $workflow, { user => { id => $user{$who}->id, name => $user{$who}->name } } );
}

sub schedule_step () { $workflow->get_step( $tdb, { slug => 'schedule' } ) }

# A Saturday 10:00, 90-minute schedule for $class, with fields overridden.
sub pattern ( $class, %override ) {
    return {
        class_project_id => $class->id,
        teacher_id       => $user{staff}->id,
        weekdays         => ['saturday'],
        start_time       => '10:00',
        duration         => 90,
        first_date       => '2027-01-02',
        last_date        => '2027-01-23',
        %override,
    };
}

# Runs the schedule step as $who with $fields; returns the run and the result.
sub generate ( $fields, $who = 'admin', $handle = $tdb ) {
    my $run = start($who);
    return ( $run, $run->process( $handle, schedule_step(), $fields ) );
}

sub errors_of ($result) { join ' ', ( $result->{errors} // [] )->@* }

sub occurrences_of ($class) {
    return [ Registry::DAO::Event->find( $tdb, { project_id => $class->id }, { -asc => 'time' } ) ];
}

sub local_starts ($class) { [ map { $_->local_start($tdb)->{start} } occurrences_of($class)->@* ] }

subtest 'the workflow is one schedule step, admin only' => sub {
    ok $workflow, 'in-studio-schedule is imported into the tenant' or return;
    my @slugs;
    for ( my $s = $workflow->first_step($tdb) ; $s ; $s = $s->next_step($tdb) ) { push @slugs, $s->slug }
    is_deeply \@slugs, [qw( schedule complete )], 'schedule, then complete';
    is_deeply $workflow->roles, ['admin'], 'its role entry is admin';
    ok Registry::WorkflowStepClasses::is_allowed('Registry::DAO::WorkflowSteps::GenerateOccurrences'),
        'GenerateOccurrences is on the step-class allowlist';
};

subtest 'a weekly Saturday 10:00 class over four weeks yields four occurrences with the class capacity' => sub {
    my $class = new_class(8);
    my $offer = Registry::DAO::Offer->create( $tdb, { name => 'One seat of ' . $class->name } )
        ->draft( $tdb, offer_terms( undef, class_project_id => $class->id ) )->publish($tdb);
    my ( $run, $result ) = generate( pattern($class) );
    is errors_of($result), '', 'the schedule is accepted' or return;

    is_deeply local_starts($class),
        [ '2027-01-02 10:00', '2027-01-09 10:00', '2027-01-16 10:00', '2027-01-23 10:00' ],
        'four Saturdays at 10:00 local';
    for my $event ( occurrences_of($class)->@* ) {
        my $row = $tdb->select( 'events', '*', { id => $event->id } )->hash;
        is $row->{location_id}, $room->id,         'at the class\'s location, the form\'s default';
        is $row->{teacher_id},  $user{staff}->id,  'taught by the chosen teacher';
        is $row->{duration},    90,                'for the stated minutes';
        is $row->{status},      'published',       'published';
        is $row->{capacity},    8,                 'with the class\'s seats';
        my ($resource) = Registry::DAO::Resource->find( $tdb, { event_id => $event->id } );
        ok $resource, 'with its own resource' or next;
        is $resource->kind,     'finite', 'a finite one';
        is $resource->capacity, 8,        'of the class\'s seats';
        ok $offer->buys( $tdb, $resource->id ), 'covered by the class offer with no new version';
    }
    is $result->{schedule_report}{created}, 4, 'the run reports four created';
    is $result->{schedule_report}{skipped}, 0, 'and none skipped';
};

subtest 'a chosen location overrides the class\'s' => sub {
    my $class = new_class();
    my ( undef, $result ) = generate( pattern( $class, location_id => $annex->id ) );
    is errors_of($result), '', 'accepted';
    is_deeply [ map { $_->location_id } occurrences_of($class)->@* ], [ ( $annex->id ) x 4 ], 'every occurrence at the annex';
};

subtest 'an occurrence with no capacity gets its class seats' => sub {
    my $class = new_class(12);
    my $event = Registry::DAO::Event->create( $tdb, {
        project_id => $class->id, location_id => $room->id, teacher_id => $user{staff}->id,
        time => '2027-05-01T14:00:00Z', duration => 60,
    } );
    my $resource = Registry::DAO::Resource->for_occurrence( $tdb, $event->id );
    is $resource->capacity, 12, 'a 12-seat resource from the class\'s default seats';
};

subtest 'only a tenant admin generates occurrences' => sub {
    my $class = new_class();
    for my $who (qw( staff parent )) {
        my ( undef, $result ) = generate( pattern($class), $who );
        like errors_of($result), qr/administrator/, "$who is refused";
    }
    is scalar occurrences_of($class)->@*, 0, 'and nothing is created';
};

subtest 'a teacher is required and must be staff or admin here' => sub {
    my $class = new_class();
    for my $case ( [ 'no', '' ], [ 'a parent', $user{parent}->id ], [ 'a malformed', 'nope' ] ) {
        my ( undef, $result ) = generate( pattern( $class, teacher_id => $case->[1] ) );
        like errors_of($result), qr/teacher/i, "$case->[0] teacher is refused";
    }
    is scalar occurrences_of($class)->@*, 0, 'and nothing is created';
};

done_testing;
