#!/usr/bin/env perl
# ABOUTME: The summer-camp enrollment Payment step refuses a charge in production before any write.
# ABOUTME: perigrin, 2026-11-26: camp checkout stays closed until it moves to the PriceOps model; in-studio opens.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::PricingProbe qw( give_tenant_terms );
use Mojo::Promise;
use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowRun;
use Registry::DAO::Family;
use Registry::DAO::Session;
use Registry::DAO::PricingPlan;
use Registry::DAO::Project;
use Registry::DAO::Event;
use Registry::DAO::Location;
use Registry::DAO::WorkflowSteps::Payment;

my $test_db = Test::Registry::DB->new;
my $db      = $test_db->db->db;

my $slug  = "camp_closed_$$";
my $admin = Registry::DAO::User->create( $db, {
    username => "cc_admin_$$", email => "cc_admin_$$\@test.example", name => 'CC Admin', user_type => 'admin' } );
Registry::DAO::Tenant->provision( $db, {
    name => "Camp Closed $$", slug => $slug, users => [$admin],
    stripe_connect_account_id => "acct_cc_$$", stripe_charges_enabled => 1, stripe_details_submitted => 1 } );
give_tenant_terms( $db, $slug, { rate => '0.025' } );
my $tdb = Registry::DAO->new( url => $test_db->uri, schema => $slug )->db;

my $buyer = Registry::DAO::User->create( $tdb, {
    username => "cc_buyer_$$", email => "cc_buyer_$$\@test.example", name => 'CC Buyer', user_type => 'parent' } );
my $location = Registry::DAO::Location->create( $tdb, {
    name => 'CC Studio', metadata => {}, time_zone => 'America/New_York',
    address_info => { street_address => '1 Way', city => 'T', state => 'FL', postal_code => '32801' } } );
my $teacher = Registry::DAO::User->create( $tdb, {
    name => 'CC Teacher', username => "cc_teacher_$$", email => "cc_teacher_$$\@test.example", user_type => 'staff' } );
my $project = Registry::DAO::Project->create( $tdb, {
    name => 'CC Camp', slug => "cc_camp_$$", status => 'published', program_type_slug => 'summer-camp', metadata => {} } );
my $event = Registry::DAO::Event->create( $tdb, {
    time => '2099-07-01 10:00:00', duration => 120, location_id => $location->id,
    project_id => $project->id, teacher_id => $teacher->id, capacity => 20, metadata => {} } );
my $session = Registry::DAO::Session->create( $tdb, {
    name => 'CC Week', start_date => '2099-07-01', end_date => '2099-07-07',
    status => 'published', capacity => 20, metadata => {} } );
$session->add_events( $tdb, $event->id );
Registry::DAO::PricingPlan->create( $tdb, {
    session_id => $session->id, plan_name => 'Standard', plan_type => 'standard', amount_cents => 15_000 } );
my $child = Registry::DAO::Family->add_child( $tdb, $buyer->id, {
    child_name => 'CC Child', birth_date => '2018-03-15', grade => '3',
    medical_info => {}, emergency_contact => { name => 'E', phone => '555-0199' } } );

# A workflow before -> pay -> after, with a run parked on pay for one camp week.
my $made = 0;
sub camp_run () {
    $made++;
    my $wf = Registry::DAO::Workflow->create( $tdb, {
        name => "CC $made", slug => "cc-$made-$$", description => 'camp checkout' } );
    $wf->add_step( $tdb, { slug => $_->[0], class => $_->[1] } ) for
        [ before => 'Registry::DAO::WorkflowStep' ], [ pay => 'Registry::DAO::WorkflowSteps::Payment' ],
        [ after  => 'Registry::DAO::WorkflowStep' ];
    my $run = $wf->new_run( $tdb, {} );
    $run->process( $tdb, $wf->first_step($tdb), {} );
    $run->update_data( $tdb, {
        user_id            => $buyer->id,
        __tenant_slug      => $slug,
        children           => [ { id => $child->id, first_name => 'CC', last_name => 'Child' } ],
        session_selections => { $child->id => $session->id },
        enrollment_items   => [ { child_id => $child->id, session_id => $session->id } ],
    } );
    return ( $wf->get_step( $tdb, { slug => 'pay' } ), Registry::DAO::WorkflowRun->find( $tdb, { id => $run->id } ) );
}

sub payments () { $tdb->query('SELECT count(*) FROM payments')->array->[0] }

local $ENV{STRIPE_SECRET_KEY} = 'ci_placeholder_not_a_stripe_key';

for my $mode (qw( production staging )) {
    subtest "$mode refuses a camp charge before any write" => sub {
        my ( $step, $run ) = camp_run();
        my $before = payments();
        my $result = do { local $ENV{MOJO_MODE} = $mode; $step->process( $tdb, { agreeTerms => 1 }, $run ) };
        ok !( $result isa Mojo::Promise ), 'refused without calling Stripe';
        like "@{ $result->{errors} // [] }", qr/not open yet.*Nothing has been charged/,
            'the parent is told why' or diag explain $result;
        is payments(), $before, 'no payment row written';
        my $data = Registry::DAO::WorkflowRun->find( $tdb, { id => $run->id } )->data;
        ok !exists $data->{payment_id}, 'the run names no payment';
    };
}

subtest 'development and test do not refuse' => sub {
    for my $mode (qw( development test )) {
        is Registry::DAO::WorkflowSteps::Payment->camp_checkout_refusal($mode), undef, "$mode is open";
    }
    local $ENV{MOJO_MODE};
    local $ENV{PLACK_ENV};
    is Registry::DAO::WorkflowSteps::Payment->camp_checkout_refusal(), undef,
        'no mode set is development, as Mojolicious reads it';
};

done_testing;
