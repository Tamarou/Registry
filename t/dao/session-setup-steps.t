#!/usr/bin/env perl
# ABOUTME: session-setup's step classes called directly: each refuses a run whose user is not an admin here,
# ABOUTME: so a workflow reusing them without roles: [admin] is still closed.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( import_all_workflows join_tenant );
use Registry::DAO;
use Registry::DAO::Resource;
use Registry::DAO::Workflow;
use Registry::Utility::WorkflowProcessor;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
import_all_workflows($dao);

my %user;
for my $role (qw( admin staff )) {
    $user{$role} = Test::Registry::Fixtures::create_user( $dao,
        { username => "steps_$role", name => "Steps \u$role", email => "$role\@steps.test", user_type => $role } );
    join_tenant( $dao, $user{$role}, $role );
}
my $field = Test::Registry::Fixtures::create_location( $db, { name => 'Steps field', slug => 'steps-field' } );

my $workflow = $dao->find( Workflow => { slug => 'session-setup' } );
sub step ($slug) { $workflow->get_step( $db, { slug => $slug } ) }

sub start ($who) {
    return Registry::WorkflowProcessor->new( dao => $dao )
        ->new_run( $workflow, { user => { id => $user{$who}->id, name => $user{$who}->name } } );
}

my %WEEK = (
    action => 'add', name => 'Steps week', first_day => '2027-06-07', last_day => '2027-06-11', weekdays => [ 1 .. 5 ],
    start  => '09:00', minutes => 420, capacity => 12, waitlist => 'none', teacher_id => $user{staff}->id,
);

subtest 'each step refuses a staff user on the run' => sub {
    my $run = start('staff');
    my $program = step('program')->process( $db,
        { program_mode => 'create', program_name => 'Staff camp', location_id => $field->id }, $run );
    like join( ' ', ( $program->{errors} // [] )->@* ), qr/Only an administrator/, 'the program step refuses';
    is $db->select( 'projects', 'id', { name => 'Staff camp' } )->rows, 0, 'and makes no program';

    my $camp = Test::Registry::Fixtures::create_project( $db, { name => 'Admin camp' } );
    $run->update_data( $db, { session_program => { project_id => $camp->id, location_id => $field->id } } );
    my $days = step('sessions')->process( $db, { %WEEK, name => 'Staff week' }, $run );
    like join( ' ', ( $days->{errors} // [] )->@* ), qr/Only an administrator/, 'the sessions step refuses';
    is_deeply [ Registry::DAO::Resource->find( $db, { name => 'Staff week' } ) ], [], 'and makes no session';
};

done_testing;
