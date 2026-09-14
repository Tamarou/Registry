#!/usr/bin/env perl
# ABOUTME: Tenant provisioning must not happen without payment having actually occurred.
# ABOUTME: Guards the no-Stripe-keys path in production and setup-intent reuse across runs.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
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
my $step = Registry::DAO::WorkflowStep->find( $db,
    { workflow_id => $workflow->id, slug => 'payment' } );
ok $step, 'the signup payment step exists' or BAIL_OUT 'no payment step';

# Enough run data that _provision_tenant would succeed if it were reached --
# otherwise these tests could pass because provisioning failed for an unrelated
# reason rather than because a guard stopped it.
sub new_run_with_profile ($slug) {
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

subtest 'without Stripe keys, development still provisions' => sub {
    local $ENV{MOJO_MODE} = 'development';
    delete local $ENV{STRIPE_SECRET_KEY};
    delete local $ENV{STRIPE_PUBLISHABLE_KEY};

    my $run    = new_run_with_profile('guard_dev');
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

    my $run = new_run_with_profile('guard_replay');
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
