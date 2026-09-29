#!/usr/bin/env perl
# ABOUTME: Tenant provisioning must fail closed when the platform cannot reach Stripe.
# ABOUTME: Guards the no-Stripe-keys path in production and setup-intent reuse across runs.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use experimental 'signatures';
use Test::Registry::DB;

use Registry::DAO qw(Workflow);
use Registry::DAO::Tenant;
use Mojo::Home;
use YAML::XS qw(Load);

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
$ENV{DB_URL} = $test_db->uri;

for my $f ( Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each ) {
    next if Load( $f->slurp )->{draft};
    Workflow->from_yaml( $dao, $f->slurp );
}

my $workflow = $dao->find( Workflow => { slug => 'tenant-signup' } );
# The commit point moved: there is no payment page, so the review button is
# what provisions. Same class, same guards.
my $step = Registry::DAO::WorkflowStep->find( $db,
    { workflow_id => $workflow->id, slug => 'review' } );
ok $step, 'the signup commit step exists' or BAIL_OUT 'no review step';

# A plan with a monthly base, offered by the platform. Nothing seeded is both:
# Studio and Empire carry one but are coming_soon, and the two legacy monthly
# plans have suspended relationships -- all three are refused by
# offered_platform_plan. Without this fixture the paid branch below cannot be
# reached at all, and the subtests that exercise its guards would pass by
# never running the code they name.
my $PLATFORM_UUID = '00000000-0000-0000-0000-000000000000';
my $paid_plan_id  = $db->query( q{
    INSERT INTO registry.pricing_plans
        (plan_scope, plan_name, plan_type, pricing_model_type, currency,
         amount_cents, requirements, pricing_configuration, metadata)
    VALUES ('tenant', 'Guard Test Monthly', 'standard', 'fixed', 'USD',
            19900, '{}'::jsonb, '{"percentage": 0.02}'::jsonb, '{}'::jsonb)
    RETURNING id
} )->hash->{id};
# consumer_id is a real users FK, so borrow whichever consumer the seeded
# platform relationships already use rather than inventing one.
my $consumer_id = $db->query(
    'SELECT consumer_id FROM registry.pricing_relationships WHERE provider_id = ? LIMIT 1',
    $PLATFORM_UUID )->hash->{consumer_id};
$db->query( q{
    INSERT INTO registry.pricing_relationships
        (provider_id, consumer_id, pricing_plan_id, status)
    VALUES (?, ?, ?, 'active')
}, $PLATFORM_UUID, $consumer_id, $paid_plan_id );

# Enough run data that _provision_tenant would succeed if it were reached --
# otherwise these tests could pass because provisioning failed for an unrelated
# reason rather than because a guard stopped it.
sub new_run_with_profile ( $slug, %opt ) {
    my $run = $workflow->new_run($db);
    $run->update_data( $db, {
        profile => {
            name              => "Guard Test $slug",
            slug              => $slug,
            organization_name => "Guard Test $slug",
            subdomain         => $slug,
            billing_email     => "admin\@$slug.example",
        },
        users => [ { username => "admin\@$slug.example", user_type => 'admin' } ],
        # Put the run on a plan with a monthly base, so the step takes the
        # branch that collects a card instead of the free-plan commit.
        $opt{paid} ? ( selected_pricing_plan => { id => $paid_plan_id } ) : (),
    } );
    return $run;
}

sub tenant_exists ($slug) {
    return !!$db->select( 'tenants', ['id'], { slug => $slug } )->hash;
}

# The path t/user-journeys/alex/01-acquire-tenant.t drives: no keys, so no
# payment is possible, so provision directly. That is right for development and
# test, and catastrophic in production -- absent keys there means a
# misconfiguration (a half-finished key rotation, say), and reading that as
# "payment not required" turns anonymous signup into a tenant factory with live
# wildcard subdomains and outbound invitation email.
subtest 'without Stripe keys, production refuses to provision' => sub {
    local $ENV{MOJO_MODE} = 'production';
    delete local $ENV{STRIPE_SECRET_KEY};
    delete local $ENV{STRIPE_PUBLISHABLE_KEY};

    my $run    = new_run_with_profile('guard_prod');
    my $result = $step->process( $db, { collect_payment_method => 1 }, $run );

    ok !$result->{tenant_created}, 'no tenant is reported as created';
    ok !tenant_exists('guard_prod'), 'and none exists in the database';
    ok $result->{errors} && @{ $result->{errors} }, 'an error is returned instead';
};

# The same guard, on a free plan, which is every signup today. It used to live
# on the card-collection branch, which a free plan never reaches -- so checking
# it there and only there would have silently stopped applying the day the
# payment page left the funnel.
subtest 'the production guard covers the free-plan commit too' => sub {
    local $ENV{MOJO_MODE} = 'production';
    delete local $ENV{STRIPE_SECRET_KEY};
    delete local $ENV{STRIPE_PUBLISHABLE_KEY};

    my $run    = new_run_with_profile('guard_prod_free');
    my $result = $step->process( $db, { terms_accepted => 1 }, $run );

    ok !$result->{tenant_created}, 'no tenant is reported as created';
    ok !tenant_exists('guard_prod_free'), 'and none exists in the database';
    ok $result->{errors} && @{ $result->{errors} }, 'an error is returned instead';
};

subtest 'without Stripe keys, development still provisions' => sub {
    local $ENV{MOJO_MODE} = 'development';
    delete local $ENV{STRIPE_SECRET_KEY};
    delete local $ENV{STRIPE_PUBLISHABLE_KEY};

    my $run    = new_run_with_profile( 'guard_dev', paid => 1 );
    my $result = $step->process( $db, { collect_payment_method => 1 }, $run );

    ok $result->{tenant_created}, 'the development path is untouched';
    ok tenant_exists('guard_dev'), 'and the tenant is provisioned';
};

# handle_setup_completion compared the submitted id against the stored one only
# when a stored one existed, so a run that never reached create_setup_intent
# skipped the comparison and was left with nothing but Stripe's own lookup --
# which happily resolves a setup intent belonging to a DIFFERENT run on the
# same account.
subtest 'a run that never started payment setup cannot complete one' => sub {
    local $ENV{MOJO_MODE} = 'development';
    local $ENV{STRIPE_SECRET_KEY}      = 'sk_test_guard_not_a_real_key';
    local $ENV{STRIPE_PUBLISHABLE_KEY} = 'pk_test_guard_not_a_real_key';

    my $run = new_run_with_profile( 'guard_replay', paid => 1 );
    is $run->data->{payment_setup}, undef, 'the run stored no setup intent';

    my $result = $step->process( $db,
        { setup_intent_id => 'seti_1SomethingTheClientChose' }, $run );

    ok !$result->{tenant_created}, 'no tenant is reported as created';
    ok !tenant_exists('guard_replay'), 'and none exists in the database';
    # Asserting the specific message, because without it this subtest passes
    # either way: an unreachable Stripe throws and the flow fails closed by
    # accident. That is not a guard -- it is a dependency on the network being
    # down. Only the explicit check produces this text.
    like join( ' ', @{ $result->{errors} // [] } ),
        qr/Payment setup was not started/,
        'refused by the run-owns-its-intent check, not by a failed Stripe call';
};

done_testing;
