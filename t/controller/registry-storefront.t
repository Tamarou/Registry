#!/usr/bin/env perl
# ABOUTME: The platform's own storefront, so the apex stops borrowing a tenant's.
# ABOUTME: registry-storefront serves tinyartempire.com; tenant-storefront serves tenants.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;

use Registry::DAO qw(Workflow);
use Mojo::Home;
use YAML::XS qw(Load);

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

# sql/test-schema.sql seeds tenant-storefront/program-listing with the PLATFORM
# marketing page -- the production hack (registry's copy of a tenant template,
# hand-edited on 2026-05-31) baked into the fixture. import_from_file is
# insert-only, so importing the real file cannot displace it, and provisioning
# would then copy the platform's page into the tenant. Drop it so the file wins.
# t/controller/tenant-storefront.t carries the same workaround for the same
# reason; #352 makes import reconcile and removes the need for both.
$dao->db->query(
    q{DELETE FROM templates WHERE name = 'tenant-storefront/program-listing'} );

my @files = Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;
for my $file (@files) {
    next if Load($file->slurp)->{draft};
    Workflow->from_yaml( $dao, $file->slurp );
}
Registry::DAO::Template->import_from_file( $dao, $_ )
  for Mojo::Home->new->child('templates')->list_tree->grep(qr/\.html\.ep$/)->each;

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper( dao => sub { $dao } );

# The apex has no subdomain, so the `tenant` helper falls back to registry.
# Serving tenant-storefront there made the platform render a TENANT template,
# which is why registry.templates' copy of tenant-storefront/program-listing was
# hand-edited in production to hold the platform's marketing page -- the single
# row whose updated_at differs from its created_at.
subtest 'the platform has a storefront workflow of its own' => sub {
    my $wf = $dao->find( Workflow => { slug => 'registry-storefront' } );
    ok $wf, 'registry-storefront exists' or return;

    my $step = $wf->first_step( $dao->db );
    ok $step, 'it has a first step' or return;

    my $template = $step->template( $dao->db );
    ok $template, 'the step has a template' or return;
    is $template->name, 'registry-storefront/landing',
        'and it is the platform landing page, not the tenant catalog';
};

subtest 'the root route picks the storefront that belongs to the requester' => sub {
    is $t->app->storefront_workflow('registry'), 'registry-storefront',
        'the platform gets its own';
    is $t->app->storefront_workflow('big_cups'), 'tenant-storefront',
        'a tenant gets the tenant one';
};

subtest 'the apex renders the platform landing page' => sub {
    $t->get_ok('/')->status_is(200);

    # The marketing page, which sells the platform.
    $t->content_like( qr/Your art deserves a real business/,
        'the platform hero renders' );
    $t->content_like( qr/Free to Start/, 'and the pricing copy' );

    # And not the tenant catalog, whose job is listing that tenant's programs.
    $t->content_unlike( qr/Browse Available Programs/,
        'the tenant catalog does not render on the apex' );
};

# copy_workflow seeds a new tenant from registry's workflows. Without this the
# platform's own storefront would be handed to every tenant, exactly the mirror
# of the bug being fixed -- and tenant-signup is already excluded for the same
# reason.
subtest 'a tenant is not given the platform storefront' => sub {
    my $tenant = Registry::DAO::Tenant->provision( $dao->db,
        { name => 'Big Cups', slug => 'big_cups', users => [] } );
    ok $tenant, 'tenant provisioned' or return;

    my $tenant_dao = $dao->schema('big_cups');
    ok !$tenant_dao->find( Workflow => { slug => 'registry-storefront' } ),
        'registry-storefront is not copied into the tenant';
    ok $tenant_dao->find( Workflow => { slug => 'tenant-storefront' } ),
        'but tenant-storefront is';

    # And the other half of the branch, over HTTP. `localhost` is a base domain
    # precisely so <slug>.localhost resolves a tenant in tests; the subdomain is
    # only honoured once the schema exists, which is why this sits after
    # provisioning rather than beside the helper assertions above.
    $t->get_ok( '/' => { Host => 'big_cups.localhost' } )->status_is(200);
    $t->content_unlike( qr/Your art deserves a real business/,
        'a tenant root does not serve the platform landing page' );
};

done_testing;
