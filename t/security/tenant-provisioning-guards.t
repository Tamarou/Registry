#!/usr/bin/env perl
# ABOUTME: Tenant provisioning must fail closed when the platform cannot reach Stripe.
# ABOUTME: Guards the no-Stripe-keys path in production, and refuses a priced offer signup cannot be paid for.

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
use Registry::DAO::Offer;
use Test::Registry::Offers qw( offer_terms );
use Registry::PriceOps::PlatformTerms qw( platform_offers_to_tenants );
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

# A platform offer to tenants with a monthly base. Signup collects no card, so
# it cannot be paid for: it must be neither listed nor accepted.
my $SOLO_V2 = '9bc4069a-f0a7-0026-3a84-aeb0d0732995';    # solo-grants-workflow-set's
my $priced_offer = Registry::DAO::Offer->create( $db, { name => 'Guard Test Monthly' } );
my $priced_version_id = $priced_offer->draft( $db, offer_terms( '00000000-0000-0000-0001-000000000001',
    price_cents   => 19900,
    payment_plans => [ { id => 'revenue_share', kind => 'percentage_of_sales', fraction => 0.02 } ],
) )->publish($db)->id;

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
        # A choice carried in run data, as the review page stores it.
        $opt{chosen} ? ( selected_offer_version => $opt{chosen} ) : (),
    } );
    return $run;
}

sub tenant_exists ($slug) {
    return !!$db->select( 'tenants', ['id'], { slug => $slug } )->hash;
}

# The path t/user-journeys/alex/01-acquire-tenant.t drives: no keys, so no
# Stripe, and signup takes no card anyway -- so provision. That is right for
# development and test, and catastrophic in production -- absent keys there
# means a misconfiguration (a half-finished key rotation, say), and a tenant
# provisioned while the platform cannot reach Stripe can never take a payment.
subtest 'production without stripe keys refuses signup' => sub {
    local $ENV{MOJO_MODE} = 'production';
    delete local $ENV{STRIPE_SECRET_KEY};
    delete local $ENV{STRIPE_PUBLISHABLE_KEY};

    # Posting the old card-collection flag changes nothing.
    for my $form ( { terms_accepted => 1 }, { collect_payment_method => 1 } ) {
        my ($flag) = keys %$form;
        my $slug   = "guard_prod_$flag";
        my $run    = new_run_with_profile($slug);
        my $result = $step->process( $db, { %$form, offer_version => $SOLO_V2 }, $run );

        ok !$result->{tenant_created}, "$flag: no tenant is reported as created";
        ok !tenant_exists($slug), "$flag: and none exists in the database";
        ok $result->{errors} && @{ $result->{errors} }, "$flag: an error is returned instead";
    }
};

subtest 'without Stripe keys, development still provisions' => sub {
    local $ENV{MOJO_MODE} = 'development';
    delete local $ENV{STRIPE_SECRET_KEY};
    delete local $ENV{STRIPE_PUBLISHABLE_KEY};

    my $run    = new_run_with_profile('guard_dev');
    my $result = $step->process( $db, { offer_version => $SOLO_V2 }, $run );

    ok $result->{tenant_created}, 'the development path is untouched';
    ok tenant_exists('guard_dev'), 'and the tenant is provisioned';
};

# Signup takes no card, so an offer with a monthly base is one it cannot be
# paid for. Fail closed: never listed, and refused however it is chosen.
subtest 'a priced platform offer is not listed and is refused' => sub {
    local $ENV{MOJO_MODE} = 'development';
    delete local $ENV{STRIPE_SECRET_KEY};
    delete local $ENV{STRIPE_PUBLISHABLE_KEY};

    ok !( grep { $_->{id} eq $priced_version_id } platform_offers_to_tenants($db)->@* ),
        'a published priced version is not listed';

    my $posted = new_run_with_profile('guard_priced_posted');
    my $result = $step->process( $db, { offer_version => $priced_version_id }, $posted );
    ok !$result->{tenant_created}, 'posted: no tenant is reported as created';
    ok !tenant_exists('guard_priced_posted'), 'posted: and none exists';
    like "@{ $result->{errors} // [] }", qr/choose one of the plans/i, 'posted: the review page asks for a listed plan';

    my $planted = new_run_with_profile( 'guard_priced_planted', chosen => $priced_version_id );
    $result = $step->process( $db, {}, $planted );
    ok !$result->{tenant_created}, 'planted: no tenant is reported as created';
    ok !tenant_exists('guard_priced_planted'), 'planted: and none exists';
    like "@{ $result->{errors} // [] }", qr/choose one of the plans/i, 'planted: the review page asks for a listed plan';

    # The provisioning re-check, past the commit's own: a choice that is not
    # a listed offer never reaches the accept.
    $result = $step->_provision_tenant( $db, $planted );
    ok !$result->{tenant_created}, 'provisioning directly: no tenant is reported as created';
    ok !tenant_exists('guard_priced_planted'), 'provisioning directly: and none exists';
    like "@{ $result->{errors} // [] }", qr/no longer offered/i, 'provisioning directly: the terms are re-quoted';
};

done_testing;
