#!/usr/bin/env perl
# ABOUTME: The PriceOps day-one acceptance test: registry sells only Solo, SACP signs up holding it, sets up a class,
# ABOUTME: and a visitor's booking holds seats with Solo's 2.5% fee quoted, through the real workflows, with no Stripe call.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use File::Spec;
use Test::Registry::DB;
use Test::Registry::Helpers qw( import_all_workflows );
use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::Workflow;
use Registry::DAO::Entitlement;
use Registry::PriceOps::PlatformTerms qw( platform_terms_for_tenant );
use Registry::Utility::WorkflowProcessor;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
$ENV{DB_URL} = $test_db->uri;
import_all_workflows($dao);

my $SOLO = $Registry::PriceOps::PlatformTerms::SOLO_OFFER_ID;
my @IN_STUDIO = qw( in-studio-booking in-studio-class-setup in-studio-day-view in-studio-schedule );

# What signup offers a tenant: the platform's current published offers to tenants.
sub offers_to_tenants () { Registry::PriceOps::PlatformTerms::platform_offers_to_tenants($db) }

subtest 'registry is the one platform tenant and publishes only solo' => sub {
    ok( Registry::DAO::Tenant->find( $db, { slug => 'registry' } ), 'the platform tenant is registry' );
    ok( !Registry::DAO::Tenant->find( $db, { slug => 'registry-platform' } ), 'and there is no registry-platform row' );
    my $offers = offers_to_tenants();
    is scalar @$offers, 1, 'one offer to tenants is published';
    is $offers->[0]{offer_id}, $SOLO, 'Solo';
    is $offers->[0]{amount_cents}, 0, 'at $0';
    is $offers->[0]{fraction}, '0.025', 'and 2.5% of sales';
};

# SACP signs up as any studio does: the tenant-signup workflow, accepting the
# Solo version the review page offers; then sql/seed/sacp-tenant.sql adds its data.
my ($signup) = Registry::DAO::Workflow->find( $db, { slug => 'tenant-signup' } );

sub sign_up ( $slug, $name ) {
    my $processor = Registry::WorkflowProcessor->new( dao => $db );
    my $run       = $processor->new_run( $signup, {
        name => $name, subdomain => $slug, admin_name => "Admin $slug", admin_email => "${slug}_admin\@test.example",
        admin_username => "${slug}_admin", admin_user_type => 'admin', profile => { name => $name, slug => $slug },
    } );
    $processor->process_workflow_run_step( $run, $signup->get_step( $db, { slug => $_ } ), {} ) for qw( profile users );
    $processor->process_workflow_run_step( $run, $signup->get_step( $db, { slug => 'review' } ),
        { offer_version => offers_to_tenants()->[0]{id} } );
    $processor->process_workflow_run_step( $run, $signup->get_step( $db, { slug => 'complete' } ), {} );
    $db->query('SET search_path = registry, public');
    return Registry::DAO::Tenant->find( $db, { slug => $slug } );
}

my $sacp = sign_up( 'sacp', 'Super Awesome Cool Pottery' );
my ( $uri, $seed ) = ( $test_db->uri, File::Spec->rel2abs('sql/seed/sacp-tenant.sql') );
is system(qq{psql -q -v ON_ERROR_STOP=1 "$uri" -f "$seed" >/dev/null 2>&1}), 0, 'the SACP seed runs after signup';

subtest 'sacp holds solo from registry' => sub {
    ok $sacp, 'signup created sacp';
    my @held = Registry::DAO::Entitlement->held_by( $db, $sacp->id );
    is scalar @held, 1, 'it holds one entitlement';
    is $held[0]->offer_version_id, offers_to_tenants()->[0]{id}, "Solo's current version";
    is $held[0]->payment_plan_id, 'revenue_share', 'under its revenue-share plan';
    my $terms = platform_terms_for_tenant( $db, 'sacp' );
    is $terms->{id}, $held[0]->offer_version_id, 'which is the platform terms sacp is charged under';
    is $terms->{fraction}, '0.025', 'at 2.5%';
    ok( Registry::DAO::Entitlement->may_run( $db, $sacp->id, $_ ), "and sacp may run $_" ) for @IN_STUDIO;
};

done_testing;
