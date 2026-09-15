#!/usr/bin/env perl
# ABOUTME: A submitted session id must be one the step actually offered.
# ABOUTME: An unresolvable id skipped every check and detonated after Stripe captured.

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO::Workflow;
use Registry::DAO::User;
use Registry::DAO::Family;
use Registry::DAO::Session;
use Registry::DAO::Project;
use Registry::DAO::Event;
use Registry::DAO::Location;
use Mojo::Home;

sub days_from_now ($days) {
    my ( $y, $m, $d ) = ( localtime( time + $days * 86_400 ) )[ 5, 4, 3 ];
    return sprintf '%04d-%02d-%02d', $y + 1900, $m + 1, $d;
}
sub birth_date_for_age ($years) {
    my ( $y, $m ) = (localtime)[ 5, 4 ];
    $y += 1900; $m += 1; $m -= 6;
    if ( $m < 1 ) { $m += 12; $y-- }
    return sprintf '%04d-%02d-15', $y - $years, $m;
}

my $test_db = Test::Registry::DB->new;
Test::Registry::Fixtures::create_tenant( $test_db->db->db,
    { name => 'Offered Set Tenant', slug => 'offered_set' } );
my $dao = Registry::DAO->new( url => $test_db->uri, schema => 'offered_set' );
my $db  = $dao->db;

my $location = Registry::DAO::Location->create( $db, {
    name => 'Offered Studio',
    address_info => { street_address => '1 Main', city => 'X', state => 'TS', postal_code => '1' },
    metadata => {},
} );
my $teacher = Registry::DAO::User->create( $db,
    { name => 'T', username => 'offered_teacher', email => 't@x.test', user_type => 'staff' } );
my $project = Registry::DAO::Project->create( $db, { name => 'Offered Project', metadata => {} } );

# Two sessions with identical linkage; only one is published. prepare_template_data
# filters on s.status = 'published', but those filters lived ONLY in the
# list-building query and never in validation.
sub session_with_event ( $name, $status, $hour ) {
    my $session = Registry::DAO::Session->create( $db, {
        name => $name, start_date => days_from_now(30), end_date => days_from_now(37),
        status => $status, capacity => 10, metadata => {},
    } );
    my $event = Registry::DAO::Event->create( $db, {
        time => sprintf( '%s %02d:00:00', days_from_now(30), $hour ), duration => 60,
        location_id => $location->id, project_id => $project->id,
        teacher_id => $teacher->id, capacity => 10, metadata => {},
    } );
    $session->add_events( $db, $event->id );
    return $session;
}

my $offered     = session_with_event( 'Offered',     'published', 9 );
my $unpublished = session_with_event( 'Unpublished', 'draft',    11 );

my $parent = Registry::DAO::User->create( $db,
    { name => 'P', username => 'offered_parent', email => 'p@x.test', user_type => 'parent' } );
my $child = Registry::DAO::Family->add_child( $db, $parent->id, {
    child_name => 'Kid', birth_date => birth_date_for_age(8), grade => '3',
    medical_info => {}, emergency_contact => { name => 'EC', phone => '555' },
} );

$dao->import_workflows(['workflows/summer-camp-registration.yaml']);
my $workflow = $dao->find( Workflow => { slug => 'summer-camp-registration' } );
my $step = $workflow->get_step( $db, { slug => 'session-selection' } );
ok $step, 'the session-selection step exists' or BAIL_OUT 'no step';

sub run_for_child () {
    my $run = $workflow->new_run($db);
    $run->update_data( $db, {
        user_id            => $parent->id,
        selected_child_ids => [ $child->id ],
        program_id         => $project->id,
        location_id        => $location->id,
    } );
    return $run;
}

sub select_session ( $run, $value ) {
    return $step->process( $db,
        { action => 'select_sessions', 'session_for_' . $child->id => $value }, $run );
}

# Positive control. Without it every refusal below could pass because the
# fixture never produced a working selection in the first place.
subtest 'a session the step offered is accepted' => sub {
    my $run = run_for_child();
    my $result = select_session( $run, $offered->id );

    ok !$result->{errors} || !@{ $result->{errors} }, 'no errors'
        or diag explain $result->{errors};
    ok $run->data->{enrollment_items}, 'the cart is built';
};

# The reported defect. Session->find returns nothing, `next unless $sess` skips
# capacity AND age silently, and the id still reaches enrollment_items because
# the only "did you choose?" test is that a selection exists. Settlement then
# runs SELECT capacity FROM sessions WHERE id = ? , finds no row and dies --
# inside the transaction, after Stripe captured.
subtest 'a session id that names nothing is refused' => sub {
    my $run = run_for_child();
    my $result = select_session( $run, 'ffffffff-ffff-4fff-8fff-ffffffffffff' );

    ok $result->{errors} && @{ $result->{errors} }, 'an error is returned';
    ok !$run->data->{enrollment_items}, 'and nothing reaches the cart';
};

# Milder variant, same line: the published/location/project filters live only in
# the list-building query, so a real session that was never offered is accepted
# whole.
subtest 'a real but unpublished session is refused' => sub {
    my $run = run_for_child();
    my $result = select_session( $run, $unpublished->id );

    ok $result->{errors} && @{ $result->{errors} }, 'an error is returned';
    ok !$run->data->{enrollment_items}, 'and nothing reaches the cart';
};

# req->params->to_hash yields an ARRAYREF for a duplicated key, so
# session_for_<child>=A&session_for_<child>=B stored a reference as the id.
subtest 'a duplicated session_for_ parameter is refused' => sub {
    my $run = run_for_child();
    my $result = select_session( $run, [ $offered->id, $unpublished->id ] );

    ok $result->{errors} && @{ $result->{errors} }, 'an error is returned';
    ok !$run->data->{enrollment_items}, 'and nothing reaches the cart';
};

# The narrowing case, which only the project_id predicate catches: a perfectly
# real, published, current session belonging to a DIFFERENT programme. The
# issue notes this admits enrolment into programmes outside the age band,
# because the age gate is checked against program_id from run data rather than
# the session's own project.
subtest "a published session from another programme is refused" => sub {
    my $other_project = Registry::DAO::Project->create( $db,
        { name => 'Other Project', metadata => {} } );
    my $other = Registry::DAO::Session->create( $db, {
        name => 'Elsewhere', start_date => days_from_now(30), end_date => days_from_now(37),
        status => 'published', capacity => 10, metadata => {},
    } );
    my $event = Registry::DAO::Event->create( $db, {
        time => sprintf( '%s 15:00:00', days_from_now(30) ), duration => 60,
        location_id => $location->id, project_id => $other_project->id,
        teacher_id => $teacher->id, capacity => 10, metadata => {},
    } );
    $other->add_events( $db, $event->id );

    my $run = run_for_child();
    my $result = select_session( $run, $other->id );

    ok $result->{errors} && @{ $result->{errors} }, 'an error is returned';
    ok !$run->data->{enrollment_items}, 'and nothing reaches the cart';
};

done_testing;
