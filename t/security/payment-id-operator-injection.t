#!/usr/bin/env perl
# ABOUTME: Proves a client-planted operator hashref in run data's owed_payment_id cannot reach a WHERE clause.
# ABOUTME: A bracketed form param expands to { '!=' => ... }, which SQL::Abstract renders as an operator.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( days_from_now );
use Test::Registry::PricingProbe qw( state_platform_terms );
use Test::Registry::Sessions qw( make_session session_offer );
use Test::Registry::Async qw( settle );
use Mojo::Promise;
use Registry::DAO;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::WorkflowRun;
use Registry::DAO::User;
use Registry::DAO::FamilyMember;
use Registry::DAO::Payment;
use Registry::PriceOps::Hold;
use Registry::Service::Stripe;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

Test::Registry::Fixtures::create_tenant($dao->db, {
    name => 'Injection Test Tenant',
    slug => 'test_injection',
});
$dao->db->query(q{UPDATE registry.tenants SET stripe_connect_account_id = 'acct_injection',
                  stripe_charges_enabled = TRUE, stripe_details_submitted = TRUE WHERE slug = 'test_injection'});
state_platform_terms( $dao->db, 'test_injection', { rate => 0 } );
local $ENV{STRIPE_SECRET_KEY} = 'sk_test_placeholder_not_real';

$dao = Registry::DAO->new(url => $test_db->uri, schema => 'test_injection');
my $db = $dao->db;

my $parent = Registry::DAO::User->create($db, {
    name      => 'Test Parent',
    username  => 'testparent',
    email     => 'parent@example.com',
    user_type => 'parent',
});
my $child = Registry::DAO::FamilyMember->create($db, {
    family_id => $parent->id, child_name => 'Kid', birth_date => '2016-01-01' });
my $session = make_session( $db, days => [ map { days_from_now($_) } 30 .. 32 ] );
my $version = session_offer( $db, $session, price_cents => 5000 );

my $workflow = Registry::DAO::Workflow->create($db, {
    name        => 'Injection Test Workflow',
    slug        => 'injection-test-workflow',
    description => 'Landing passthrough followed by the session cart payment step',
});

# The landing step is a bare WorkflowStep with no outcome definition, so
# validate() is a no-op and process() persists whatever the client posted.
my $landing = Registry::DAO::WorkflowStep->create($db, {
    workflow_id => $workflow->id,
    slug        => 'landing',
    class       => 'Registry::DAO::WorkflowStep',
    description => 'Landing',
});
Registry::DAO::WorkflowStep->create($db, {
    workflow_id => $workflow->id,
    slug        => 'payment',
    class       => 'Registry::DAO::WorkflowSteps::SessionCartPayment',
    description => 'Payment',
    depends_on  => $landing->id,
});
$workflow->update($db, { first_step => 'landing' }, { id => $workflow->id });

my $payment_step = $workflow->get_step($db, { slug => 'payment' });

# An unrelated pending payment belonging to this tenant.
sub make_victim {
    return Registry::DAO::Payment->create($db, {
        user_id      => $parent->id,
        amount_cents => 7000,
        metadata     => { tenant_slug => 'test_injection' },
    });
}

# Plant the operator hashref exactly the way an unauthenticated GET/POST would:
# owed_payment_id[!=]=<uuid> expands to owed_payment_id => { '!=' => <uuid> }.
# The run owes a one-child cart whose seat it holds.
sub planted_run {
    my $run = $workflow->new_run($db);
    $run->process($db, $landing, {
        'owed_payment_id[!=]' => '00000000-0000-0000-0000-000000000000',
    });
    my $hold = Registry::PriceOps::Hold->place( $db, {
        resource_id => $session->id, units => 1, workflow_run_id => $run->id,
        expires_at  => \"now() + interval '15 minutes'" } );
    $run->update_data($db, {
        user_id       => $parent->id,
        __tenant_slug => 'test_injection',
        owed_payment  => { purpose => 'session_checkout', amount_cents => 5000, lines => [ {
            family_member_id => $child->id, resource_id => $session->id, offer_version_id => $version->id,
            payment_plan_id => 'pay', kind => 'one_time', share_cents => 5000, parts => undef,
            hold_id => $hold->id } ] },
    });
    return Registry::DAO::WorkflowRun->find( $db, { id => $run->id } );
}

subtest 'the operator hashref really does land in run data' => sub {
    my $run = planted_run();
    is ref $run->data->{owed_payment_id}, 'HASH',
        'bracketed param expands to a hashref in run data';
    is $run->data->{owed_payment_id}{'!='}, '00000000-0000-0000-0000-000000000000',
        'and carries the operator the client chose';
};

subtest 'owed_payment never binds a non-scalar owed_payment_id' => sub {
    my $victim = make_victim();
    my $run    = planted_run();

    my $out = $payment_step->owed_payment($db, $run);
    my $payment = $out->{payment} or return fail 'no payment: ' . explain $out;

    isnt $payment->id, $victim->id, 'the unrelated payment is not taken as this run\'s';
    is $payment->metadata->{workflow_run_id}, $run->id, 'a payment of its own is started';
    my $row = $db->select('payments', '*', { id => $victim->id })->hash;
    is $row->{amount_cents}, 7000, 'unrelated payment amount untouched';
    is $row->{status}, 'pending', 'and its status';
};

subtest 'the return refuses a non-scalar owed_payment_id' => sub {
    make_victim();
    my $run = planted_run();

    my $retrieved = 0;
    no warnings 'redefine';
    local *Registry::Service::Stripe::retrieve_payment_intent_async =
        sub { $retrieved++; Mojo::Promise->resolve( { id => 'pi_never_sent', status => 'succeeded' } ) };

    my $out = settle( $payment_step->handle_payment_callback($db, $run, {
        payment_intent_id => 'pi_never_sent',
    }) );

    is_deeply $out->{errors}, ['No payment was started here.'], 'refused before looking up a payment';
    is $retrieved, 0, 'and Stripe is never asked about the intent';
};

done_testing;
