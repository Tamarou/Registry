# ABOUTME: The session edit screen is reachable, role-guarded, and applies all three fields.
# ABOUTME: Before #419 the only session route in the application was the publish toggle.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use experimental 'signatures';
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Helpers qw( authenticate_as );
use Registry::DAO::Location;
use Registry::DAO::Project;
use Registry::DAO::Event;
use Registry::DAO::Session;
use Registry::DAO::Enrollment;
use Registry::DAO::PricingPlan;
use Registry::DAO::Family;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;
my $db = $dao->db;

my $admin = $dao->create( User => {
    username => 'ses_admin', name => 'Ses Admin', user_type => 'admin',
    email => 'ses_admin@test.local', password => 'x' } );
my $parent = $dao->create( User => {
    username => 'ses_parent', name => 'Ses Parent', user_type => 'parent',
    email => 'ses_parent@test.local' } );

my $n = 0;
sub a_session ( $capacity = 10 ) {
    $n++;
    my $loc = Registry::DAO::Location->create( $db, {
        name => "SES Loc $n$$", slug => "ses_loc_$n$$", address_info => {}, metadata => {} } );
    my $proj = Registry::DAO::Project->create( $db, {
        name => "SES Proj $n$$", status => 'published',
        program_type_slug => 'summer-camp', metadata => {} } );
    my $teacher = $dao->create( User => {
        username => "ses_t_$n$$", name => 'SES T', user_type => 'staff',
        email => "ses_t_$n$$\@test.local" } );
    my $event = Registry::DAO::Event->create( $db, {
        location_id => $loc->id, project_id => $proj->id, teacher_id => $teacher->id,
        time => \'NOW()', duration => 60, capacity => $capacity, metadata => {} } );
    my $s = Registry::DAO::Session->create( $db, {
        name => "SES Session $n$$", status => 'published',
        capacity => $capacity, waitlist_enabled => 1, metadata => {} } );
    $s->add_events( $db, $event->id );
    return $s;
}
sub reload ($s) { Registry::DAO::Session->find( $db, { id => $s->id } ) }

sub as_admin () {
    my $t = Test::Registry::Mojo->new('Registry');
    $t->app->helper( dao => sub { $dao } );
    authenticate_as( $t, $admin );
    return $t;
}

subtest 'the screen renders the three editable fields' => sub {
    my $session = a_session(10);
    Registry::DAO::PricingPlan->create( $db, {
        session_id => $session->id, plan_name => 'Standard',
        plan_type => 'standard', amount_cents => 5000 } );

    my $t = as_admin();
    $t->get_ok("/admin/sessions/@{[ $session->id ]}/edit")->status_is(200)
      ->content_like( qr/name="capacity"/,        'capacity' )
      ->content_like( qr/name="price_cents"/,     'price' )
      ->content_like( qr/name="waitlist_enabled"/, 'the waitlist toggle' )
      ->content_like( qr/\$50\.00/, 'and shows the current price as money' );
};

subtest 'saving applies all three' => sub {
    my $session = a_session(10);
    Registry::DAO::PricingPlan->create( $db, {
        session_id => $session->id, plan_name => 'Standard',
        plan_type => 'standard', amount_cents => 5000 } );

    my $t = as_admin();
    $t->post_ok( "/admin/sessions/@{[ $session->id ]}/settings" => form => {
        capacity => 25, price_cents => 7500 } )->status_is(302);

    my $fresh = reload($session);
    is $fresh->capacity, 25, 'capacity saved';
    is $fresh->waitlist_enabled, 0,
        'an unticked checkbox turns the waitlist off, rather than being ignored';

    my $plans = Registry::DAO::PricingPlan->get_pricing_plans( $db, $session->id );
    my ($current) = grep { !defined $_->superseded_at } @$plans;
    is $current->amount_cents, 7500, 'the price was revised';
};

subtest 'the enrolled floor is shown before it is hit' => sub {
    my $session = a_session(10);
    for ( 1 .. 3 ) {
        $n++;
        my $child = Registry::DAO::Family->add_child( $db, $parent->id, {
            child_name => "SES Kid $n", birth_date => '2015-01-01', grade => '4',
            medical_info => {}, emergency_contact => { name => 'x', phone => '5' } } );
        Registry::DAO::Enrollment->create( $db, {
            session_id => $session->id, student_id => $child->id,
            parent_id => $parent->id, status => 'active' } );
    }

    my $t = as_admin();
    $t->get_ok("/admin/sessions/@{[ $session->id ]}/edit")->status_is(200)
      ->content_like( qr/id="enrolled-floor"/, 'the floor is stated on the page' )
      ->content_like( qr/cannot go below 3/,   'with the number' );

    # And refused if attempted anyway, with the count in the message.
    $t->post_ok( "/admin/sessions/@{[ $session->id ]}/settings" => form => {
        capacity => 1, waitlist_enabled => 1 } )->status_is(302);
    is reload($session)->capacity, 10, 'capacity unchanged';
};

subtest 'a parent cannot reach it' => sub {
    my $session = a_session(10);
    my $t = Test::Registry::Mojo->new('Registry');
    $t->app->helper( dao => sub { $dao } );
    authenticate_as( $t, $parent );

    $t->get_ok("/admin/sessions/@{[ $session->id ]}/edit")->status_isnt(200);
    $t->post_ok( "/admin/sessions/@{[ $session->id ]}/settings" => form => {
        capacity => 99 } );
    is reload($session)->capacity, 10,
        'and cannot change it by posting past the screen';
};

done_testing;
