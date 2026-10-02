#!/usr/bin/env perl
# ABOUTME: A tenant that cannot take payment must not look like an offline-payment offer to a parent.
# ABOUTME: And the tenant has to be told, rather than finding out when a parent gives up.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use experimental 'signatures';
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::Tenant;
use Registry::DAO::Session;
use Registry::DAO::PricingPlan;
use Registry::DAO::WorkflowSteps::Payment;

my $test_db     = Test::Registry::DB->new;
my $registry    = $test_db->db;
my $registry_db = $registry->db;

my $tenant = Test::Registry::Fixtures::create_tenant( $registry_db, {
    name => 'No Payments Studio', slug => 'no_payments',
} );
$registry_db->query( 'SELECT clone_schema(?)', 'no_payments' );
my $dao = Registry::DAO->new( url => $test_db->uri, schema => 'no_payments' );
my $db  = $dao->db;

# The tenant has no Connect account at all, which is the state every tenant
# starts in and the one the publish gate exists for.
ok !$tenant->stripe_connect_ready, 'the fixture tenant cannot take payment';

subtest 'the checkout refusal does not offer a route that records nothing' => sub {
    # Asserted against the method, not by grepping the source: my first version
    # matched /Online payment[^']*/ against the file, which stops at the end of
    # the first string literal and never saw the second half -- so it passed
    # while the old wording was still there.
    my $message = Registry::DAO::WorkflowSteps::Payment->payment_unavailable_message;

    # The old wording ended "Please contact the program organizer to complete
    # enrollment", which describes collecting money at the event -- something
    # Registry cannot record, so the enrolment never happened and nobody knew the
    # parent had tried. #410 settled that the Stripe gate stays, so the refusal
    # must not imply a way around it.
    unlike $message, qr/contact the program organizer/i,
        'it does not point the parent at an off-platform arrangement';
    like $message, qr/nothing has been charged/i,
        'it says no money moved';
    like $message, qr/notified/i,
        'and that somebody who can fix it has been told';
};

# Something priced and published, which is the only state worth warning about:
# a tenant running free programmes legitimately has no Connect account, and the
# publish gate lets them publish without one.
sub a_priced_published_session () {
    state $n = 0;
    $n++;
    my $session = Registry::DAO::Session->create( $db, {
        name => "Unsellable Week $n", start_date => '2026-01-01',
        end_date => '2026-12-31', status => 'published', capacity => 10,
        metadata => {},
    } );
    Registry::DAO::PricingPlan->create( $db, {
        session_id => $session->id, plan_name => "Plan $n",
        amount_cents => 5000, currency => 'USD',
    } );
    return $session;
}

# The tenant-facing half. A parent should never be the first to find out.
subtest 'the dashboard warns the tenant that a paid session cannot sell' => sub {
    a_priced_published_session();
    my $workflow = Registry::DAO::Workflow->create( $db, {
        name => 'Dash', slug => 'dash-unsellable', description => 'd',
    } );
    Registry::DAO::WorkflowStep->create( $db, {
        workflow_id => $workflow->id, slug => 'dashboard-overview',
        class => 'Registry::DAO::WorkflowSteps::AdminDashboardOverview',
        description => 'Overview',
    } );
    $workflow->update( $db, { first_step => 'dashboard-overview' }, { id => $workflow->id } );
    $workflow = Registry::DAO::Workflow->find( $db, { id => $workflow->id } );
    my $step = $workflow->get_step( $db, { slug => 'dashboard-overview' } );

    my $run = $workflow->new_run($db);
    $run->update_data( $db, { __tenant_slug => 'no_payments' } );

    my $data = $step->prepare_template_data( $db, $run );

    ok $data->{payments_blocked},
        'the dashboard is told that payments are not set up';
    is $data->{payments_blocked}{sessions}, 1,
        'and how many published sessions cannot take money';
    like $data->{payments_blocked}{action_url}, qr{/admin/billing},
        'and where to go about it';
};

subtest 'a tenant with nothing priced is not nagged about Connect' => sub {
    # Free programmes do not need a Connect account, and the publish gate agrees.
    my $free = Test::Registry::Fixtures::create_tenant( $registry_db, {
        name => 'Free Studio', slug => 'free_studio',
    } );
    $registry_db->query( 'SELECT clone_schema(?)', 'free_studio' );
    my $free_dao = Registry::DAO->new( url => $test_db->uri, schema => 'free_studio' );

    my $workflow = Registry::DAO::Workflow->create( $free_dao->db, {
        name => 'Dash', slug => 'dash-free', description => 'd',
    } );
    Registry::DAO::WorkflowStep->create( $free_dao->db, {
        workflow_id => $workflow->id, slug => 'dashboard-overview',
        class => 'Registry::DAO::WorkflowSteps::AdminDashboardOverview',
        description => 'Overview',
    } );
    $workflow->update( $free_dao->db, { first_step => 'dashboard-overview' },
        { id => $workflow->id } );
    $workflow = Registry::DAO::Workflow->find( $free_dao->db, { id => $workflow->id } );
    my $step = $workflow->get_step( $free_dao->db, { slug => 'dashboard-overview' } );

    my $run = $workflow->new_run( $free_dao->db );
    $run->update_data( $free_dao->db, { __tenant_slug => 'free_studio' } );

    ok !$step->prepare_template_data( $free_dao->db, $run )->{payments_blocked},
        'no Connect account and nothing priced is not a problem';
};

subtest 'a tenant that can take payment is not warned' => sub {
    my $ready = Test::Registry::Fixtures::create_tenant( $registry_db, {
        name => 'Paid Up Studio', slug => 'paid_up',
    } );
    $registry_db->query(
        'UPDATE registry.tenants SET stripe_connect_account_id = ?,
            stripe_charges_enabled = TRUE, stripe_details_submitted = TRUE
          WHERE id = ?', 'acct_test_paid_up', $ready->id );

    my $workflow = Registry::DAO::Workflow->find( $db, { slug => 'dash-unsellable' } );
    my $step = $workflow->get_step( $db, { slug => 'dashboard-overview' } );
    my $run  = $workflow->new_run($db);
    $run->update_data( $db, { __tenant_slug => 'paid_up' } );

    ok !$step->prepare_template_data( $db, $run )->{payments_blocked},
        'no warning when there is nothing to warn about';
};

done_testing;
