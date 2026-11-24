#!/usr/bin/env perl
# ABOUTME: Signup provisioning grants the new tenant, in registry, an in-effect entitlement to the platform's one published offer to tenants.
# ABOUTME: A bridge test: 01a20416-6d40 replaces the grant with the accept primitive and deletes this file.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;

use Test::Registry::DB;
use Registry::DAO;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowRun;
use Registry::DAO::Tenant;
use Registry::DAO::Entitlement;
use Registry::DAO::Offer;
use Test::Registry::Offers qw( offer_terms );

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

$dao->import_workflows( ['workflows/tenant-signup.yml'] );
my ($workflow) = Registry::DAO::Workflow->find( $db, { slug => 'tenant-signup' } );
my ($review)   = $workflow->get_step( $db, { slug => 'review' } );

# The bootstrap seed's fixed ids for Solo v1 and the resource it buys.
my $SOLO_V1            = '00000000-0000-0000-0003-000000000001';
my $PAYMENT_PROCESSING = '00000000-0000-0000-0001-000000000001';

# A signup run that has reached the review page, whose button provisions.
sub signup_run ($slug) {
    return Registry::DAO::WorkflowRun->create( $db, {
        workflow_id => $workflow->id,
        data        => {
            name            => "Studio $slug",
            subdomain       => $slug,
            admin_name      => 'Grant Admin',
            admin_email     => "${slug}_admin\@test.example",
            admin_username  => "${slug}_admin",
            admin_user_type => 'admin',
            profile         => { name => "Studio $slug", slug => $slug },
        },
    } );
}

sub tenant_id ($slug) {
    my $row = $db->query( 'SELECT id FROM registry.tenants WHERE slug = ?', $slug )->hash;
    return $row && $row->{id};
}

sub held ($slug) {
    my $id = tenant_id($slug) or return [];
    return [ Registry::DAO::Entitlement->find( $db, { holder_tenant_id => $id } ) ];
}

subtest 'signup grants an entitlement to the published platform offer' => sub {
    my $slug = 'granted_studio';
    signup_run($slug)->process( $db, $review, {} );

    ok tenant_id($slug), 'the tenant was provisioned';
    my $held = held($slug);
    is scalar @$held, 1, 'it holds one entitlement in registry';
    my $e = $held->[0];
    is $e->offer_version_id, $SOLO_V1, 'to Solo v1, the one offer to tenants';
    is $e->payment_plan_id, 'revenue_share', 'under its percentage-of-sales plan';
    ok $e->is_in_effect($db), 'in effect now';
};

subtest 'the platform self-offer is never the one granted' => sub {
    my $slug = 'not_self_studio';
    signup_run($slug)->process( $db, $review, {} );
    my ($e) = held($slug)->@*;
    ok $e, 'an entitlement was granted';
    is_deeply $e && $e->offer_version($db)->conditions, [],
        'to a version offered to tenants, not one restricted to its offerer';
};

subtest 'provisioning the same run twice leaves one tenant and one entitlement' => sub {
    my $slug = 'twice_studio';
    my $run  = signup_run($slug);
    $run->process( $db, $review, {} );
    my $again = eval { $run->process( $db, $review, {} ) };
    is $@, '', 'the second press does not die';
    is $again && $again->{tenant}, tenant_id($slug), 'and answers with the same tenant';
    is $db->query( 'SELECT count(*) FROM registry.tenants WHERE slug LIKE ?', "$slug%" )->array->[0],
        1, 'one tenant';
    is scalar held($slug)->@*, 1, 'one entitlement';
};

# Nothing in registry but the grants above and the platform's own.
sub entitlement_count { $db->query('SELECT count(*) FROM registry.entitlements')->array->[0] }

subtest 'two published platform offers create no tenant' => sub {
    my $offer = Registry::DAO::Offer->create( $db, { name => 'Studio' } );
    $offer->draft( $db, offer_terms( $PAYMENT_PROCESSING,
        price_cents   => 0,
        payment_plans => [ { id => 'revenue_share', kind => 'percentage_of_sales', fraction => 0.02 } ],
    ) )->publish($db);

    my $before = entitlement_count();
    eval { signup_run('two_offer_studio')->process( $db, $review, {} ) };
    like $@, qr/exactly one/, 'provisioning refuses';
    ok !tenant_id('two_offer_studio'), 'no tenant';
    is entitlement_count(), $before, 'no entitlement';
};

subtest 'no published platform offer creates no tenant' => sub {
    $db->query( q{UPDATE registry.offer_versions SET superseded_at = now()
                   WHERE published_at IS NOT NULL AND superseded_at IS NULL
                     AND NOT conditions @> '[{"kind": "holder_is_offerer"}]'} );

    my $before = entitlement_count();
    eval { signup_run('no_offer_studio')->process( $db, $review, {} ) };
    like $@, qr/exactly one/, 'provisioning refuses, rather than granting the self-offer';
    ok !tenant_id('no_offer_studio'), 'no tenant';
    is entitlement_count(), $before, 'no entitlement';
};

$test_db->cleanup_test_database;
done_testing;
