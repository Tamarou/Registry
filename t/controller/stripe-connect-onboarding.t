#!/usr/bin/env perl
# ABOUTME: A tenant must be able to REACH stripe_connect_ready through the product, not just be given it.
# ABOUTME: Six fixtures wrote stripe_connect_account_id by hand and nothing under lib/ ever did (#439).

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use experimental qw(defer signatures);
use Test::More import => [qw( done_testing is isnt ok like unlike subtest diag )];
defer { done_testing };

use Mojo::File qw( path );
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Helpers qw(authenticate_as);
use Registry::DAO::PricingPlan;
use Registry::Service::Stripe;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper( dao => sub { $dao } );

my $admin = $dao->create( User => { username => 'connect_admin', user_type => 'admin' } );

# ---------------------------------------------------------------------------
# The assertion whose absence is #439.
#
# Every test that needed a Connect-ready tenant wrote the column itself:
#
#   t/controller/session-publish-connect-gate.t
#   t/dao/payment-intent-destination-charge.t
#   t/dao/payment-step-readiness-gate.t
#   t/integration/tenant-paid-enrollment.t
#   t/stripe-live/paid-enrollment.t
#
# Every one of them passed. All of them were grading the layer underneath the
# screen: the gate they exercised could never fire in production because
# nothing in the product could put a tenant on the good side of it. A fixture
# cannot satisfy this subtest -- it asks whether shipped code can.
# ---------------------------------------------------------------------------
subtest 'the product can create a connected account at all' => sub {
    ok Registry::Service::Stripe->can('create_account_async'),
        'the Stripe service can create a connected account';
    ok Registry::Service::Stripe->can('create_account_link_async'),
        'and mint the hosted onboarding link that completes it';
    ok Registry::Service::Stripe->can('retrieve_account_async'),
        'and read the account back to learn whether it worked';

    # The column is the charge-time authority: Payment::_connect_params reads it
    # to route the money, and Webhooks::_process_account_updated matches tenants
    # by it. If only tests write it, no tenant ever has one.
    my @writers;
    for my $file ( path('lib')->list_tree->grep(qr/\.pm$/)->each ) {
        my $src = $file->slurp;
        push @writers, $file->to_rel('lib')->to_string
            if $src =~ /stripe_connect_account_id\s*=>/;
    }
    ok scalar(@writers),
        'something under lib/ writes tenants.stripe_connect_account_id'
        or diag 'nothing does -- the readiness gate can never pass';
    diag "writers: @writers" if @writers;
};

subtest 'a fresh tenant is offered the way to switch payments on' => sub {
    authenticate_as( $t, $admin );

    $t->get_ok('/admin/billing')
      ->status_is(200)
      ->content_like(qr/Set up payments/i,
          'the screen offers the action, rather than describing a step with no door')
      ->content_like(qr{action="[^"]*/admin/billing/connect"},
          'and the action posts somewhere');

    # Not "you are all set". A tenant with no account cannot take a payment, and
    # the page that says otherwise is worse than no page.
    $t->get_ok('/admin/billing')
      ->content_unlike(qr/You can take payments/i,
          'and does not claim payments already work');
};

subtest 'the state the screen reports follows the tenant row' => sub {
    authenticate_as( $t, $admin );

    # Half-onboarded: Stripe has an account but has not approved it. This is the
    # state a tenant lands in by abandoning the hosted flow, and it is the one
    # that used to be indistinguishable from ready.
    $dao->db->query(
        'UPDATE registry.tenants SET stripe_connect_account_id = ?,
            stripe_charges_enabled = FALSE, stripe_details_submitted = FALSE
         WHERE slug = ?', 'acct_probe_incomplete', 'registry' );

    $t->get_ok('/admin/billing')
      ->status_is(200)
      ->content_like(qr/Stripe still needs something from you/i,
          'a started-but-unapproved account reads as unfinished')
      ->content_unlike(qr/You can take payments/i, 'and not as ready');

    $dao->db->query(
        'UPDATE registry.tenants SET stripe_charges_enabled = TRUE,
            stripe_details_submitted = TRUE WHERE slug = ?', 'registry' );

    $t->get_ok('/admin/billing')
      ->status_is(200)
      ->content_like(qr/You can take payments/i, 'an approved account reads as ready');

    $dao->db->query(
        'UPDATE registry.tenants SET stripe_connect_account_id = NULL,
            stripe_charges_enabled = FALSE, stripe_details_submitted = FALSE
         WHERE slug = ?', 'registry' );
};

subtest 'starting onboarding is admin-only' => sub {
    # A SECOND Test::Mojo, deliberately. authenticate_as installs a
    # before_dispatch hook that fills the session only when it is empty, and
    # each call adds another hook -- so calling it again on $t leaves the first
    # user logged in and the assertion below would pass no matter what the
    # route did. Nothing currently asserts staff exclusion from the admin_only
    # group at all; the domains routes share the gap.
    my $staff = $dao->create( User => { username => 'connect_staff', user_type => 'staff' } );

    my $t_staff = Test::Registry::Mojo->new('Registry');
    $t_staff->app->helper( dao => sub { $dao } );
    authenticate_as( $t_staff, $staff );

    # Staff reach other /admin/* routes; this one decides where the money lands
    # and is the tenant's own Stripe identity.
    $t_staff->get_ok('/admin/dashboard');
    is $t_staff->tx->res->code, 200,
        'the staff session is real -- staff do reach other /admin routes';

    $t_staff->get_ok('/admin/billing');
    isnt $t_staff->tx->res->code, 200, 'but not the billing screen';

    $t_staff->post_ok('/admin/billing/connect');
    isnt $t_staff->tx->res->code, 302, 'and cannot start onboarding';
};

# ---------------------------------------------------------------------------
# The refusal that had nowhere to send anyone.
# ---------------------------------------------------------------------------
subtest 'the publish refusal names the screen that fixes it' => sub {
    authenticate_as( $t, $admin );

    my $program = $dao->create( Project => {
        status => 'published', name => 'Connect Door Camp',
        program_type_slug => 'summer-camp', metadata => {},
    } );
    my $location = $dao->create( Location => {
        name => 'Connect Door Studio', slug => 'connect-door-studio',
        address_info => { street => '1 Main', city => 'Orlando', state => 'FL' },
        metadata => {},
    } );
    my $teacher = $dao->create( User => { username => 'door_teacher', user_type => 'staff' } );

    my $session = $dao->create( Session => {
        name => 'Priced, no Connect', start_date => '2026-01-01',
        end_date => '2026-12-31', status => 'draft', capacity => 10, metadata => {},
    } );
    my $event = $dao->create( Event => {
        time => '2026-06-15 09:00:00', duration => 60,
        location_id => $location->id, project_id => $program->id,
        teacher_id => $teacher->id, capacity => 10, metadata => {},
    } );
    $session->add_events( $dao->db, $event->id );

    Registry::DAO::PricingPlan->create( $dao->db, {
        session_id => $session->id, plan_name => 'Door Plan',
        amount_cents => 5000, currency => 'USD',
    } );

    $t->post_ok( '/admin/sessions/' . $session->id . '/status' => form => { status => 'published' } )
      ->status_is(409)
      ->json_has('/action_url', 'the refusal carries somewhere to go')
      ->json_is('/action_url', '/admin/billing',
          'and it is the onboarding screen');
};

$test_db->cleanup_test_database;
