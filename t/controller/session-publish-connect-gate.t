#!/usr/bin/env perl
# ABOUTME: A priced session cannot be published until the tenant can actually take money.
# ABOUTME: The Connect check existed only at checkout, so parents discovered it, not tenants.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Helpers qw(authenticate_as);
use Registry::DAO::PricingPlan;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper( dao => sub { $dao } );

my $admin = $dao->create( User => { username => 'publish_admin', user_type => 'admin' } );
authenticate_as( $t, $admin );

my $program = $dao->create( Project => {
    status => 'published', name => 'Connect Gate Camp',
    program_type_slug => 'summer-camp', metadata => {},
} );

my $location = $dao->create( Location => {
    name => 'Connect Gate Studio', slug => 'connect-gate-studio',
    address_info => { street => '1 Main', city => 'Orlando', state => 'FL' },
    metadata => {},
} );
my $teacher = $dao->create( User => { username => 'gate_teacher', user_type => 'staff' } );

# A session's programme is reached through its events, not a column on sessions;
# set_session_status calls $session->project_id($db), which walks that path.
# events is unique on (project_id, location_id, time), so each session needs its
# own slot rather than a shared fixed timestamp.
my $slot = 0;
sub new_session ($name) {
    my $hour = 8 + $slot++;
    my $s = $dao->create( Session => {
        name => $name, start_date => '2026-01-01', end_date => '2026-12-31',
        status => 'draft', capacity => 10, metadata => {},
    } );
    my $event = $dao->create( Event => {
        time => sprintf( '2026-06-15 %02d:00:00', $hour ), duration => 60,
        location_id => $location->id, project_id => $program->id,
        teacher_id => $teacher->id, capacity => 10, metadata => {},
    } );
    $s->add_events( $dao->db, $event->id );
    return $s;
}

sub price ( $session, $cents ) {
    Registry::DAO::PricingPlan->create( $dao->db, {
        session_id => $session->id, plan_name => "Plan $cents",
        amount_cents => $cents, currency => 'USD',
    } );
}

sub set_connect ($ready) {
    $dao->db->query(
        'UPDATE registry.tenants SET stripe_connect_account_id = ?,
            stripe_charges_enabled = ?, stripe_details_submitted = ? WHERE slug = ?',
        ( $ready ? 'acct_test_gate' : undef ), $ready, $ready, 'registry' );
}

sub publish ($session) {
    $t->post_ok( "/admin/sessions/" . $session->id . "/status" => form => { status => 'published' } );
    return $t->tx->res->code;
}

# WorkflowSteps/Payment.pm:166 already refuses to charge unless the tenant is
# stripe_connect_ready, and draws the line at $payment_info->{total} > 0. But
# that is the checkout, so the first person to discover a tenant cannot take
# money is a PARENT, told to "contact the program organizer". The same line is
# drawn here, where the tenant can still act on it.
subtest 'a priced session will not publish without Connect' => sub {
    set_connect(0);
    my $session = new_session('Priced, no Connect');
    price( $session, 5000 );

    is publish($session), 409, 'publishing is refused';

    my $after = Registry::DAO::Session->find( $dao->db, { id => $session->id } );
    is $after->status, 'draft', 'and the session stays a draft';
};

# Free programs are a legitimate use with no Connect account -- the existing
# total > 0 check draws the line in the right place and this must not move it.
subtest 'a free session publishes without Connect' => sub {
    set_connect(0);
    my $session = new_session('Free, no Connect');
    price( $session, 0 );

    is publish($session), 200, 'publishing succeeds';

    my $after = Registry::DAO::Session->find( $dao->db, { id => $session->id } );
    is $after->status, 'published', 'and the session is published';
};

subtest 'a session with no pricing plan at all publishes' => sub {
    set_connect(0);
    my $session = new_session('Unpriced, no Connect');

    is publish($session), 200, 'publishing succeeds';
};

subtest 'a priced session publishes once Connect is ready' => sub {
    set_connect(1);
    my $session = new_session('Priced, Connect ready');
    price( $session, 5000 );

    is publish($session), 200, 'publishing succeeds';

    my $after = Registry::DAO::Session->find( $dao->db, { id => $session->id } );
    is $after->status, 'published', 'and the session is published';
};

subtest 'unpublishing a priced session is never blocked' => sub {
    set_connect(0);
    my $session = new_session('Withdrawing');
    price( $session, 5000 );
    $session->update( $dao->db, { status => 'published' } );

    $t->post_ok( "/admin/sessions/" . $session->id . "/status" => form => { status => 'draft' } );
    is $t->tx->res->code, 200,
        'a tenant whose Connect lapsed can still withdraw what is already listed';
};

done_testing;
