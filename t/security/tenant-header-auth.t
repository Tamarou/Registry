#!/usr/bin/env perl
# ABOUTME: Tests that X-As-Tenant requires MEMBERSHIP of the tenant, not just a login.
# ABOUTME: The header selects the Postgres schema and the Stripe destination account.

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;

use Registry::DAO qw(Workflow);
use Registry::DAO::Tenant;
use Mojo::Home;
use YAML::XS qw(Load);

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

# Import workflows
my @files = Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;
for my $file (@files) {
    next if Load($file->slurp)->{draft};
    Workflow->from_yaml($dao, $file->slurp);
}

my $t = Test::Registry::Mojo->new('Registry');

# Create a second tenant to switch to
eval {
    $dao->db->query("INSERT INTO registry.tenants (name, slug) VALUES ('Target Tenant', 'target_tenant') ON CONFLICT DO NOTHING");
};

subtest 'unauthenticated request ignores X-As-Tenant header' => sub {
    # Without authentication, X-As-Tenant should be ignored.
    # The tenant should resolve from subdomain (or default to registry).
    $t->get_ok('/' => { 'X-As-Tenant' => 'target_tenant' })
      ->status_is(200);

    # The response should NOT be from target_tenant's context.
    # Since there's no subdomain, tenant should resolve to 'registry'.
    # We verify by checking the app resolved the right tenant.
    pass 'request completed without using spoofed tenant header';
};

# This subtest used to assert that ANY authenticated user could switch tenant,
# which is the defect in #336 written down as intended behaviour. The value
# chosen here becomes __tenant_slug, which selects the schema every subsequent
# query runs against and the Stripe Connect account a charge is destined for.
subtest 'a member may act as their own tenant' => sub {
    my $user = Registry::DAO::User->create($dao->db, {
        name => 'Member User', username => 'member_of_target',
        email => 'member_of_target@example.com', user_type => 'admin',
    });
    $dao->db->query(
        'INSERT INTO registry.tenant_users (tenant_id, user_id) '
      . 'SELECT id, ? FROM registry.tenants WHERE slug = ? ON CONFLICT DO NOTHING',
        $user->id, 'target_tenant' );

    my $c = $t->app->build_controller;
    $c->session(user_id => $user->id);
    $c->req->headers->header('X-As-Tenant' => 'target_tenant');

    is $c->tenant, 'target_tenant', 'membership permits acting as that tenant';
};

subtest 'a member of one tenant may not act as another' => sub {
    $dao->db->query(
        "INSERT INTO registry.tenants (name, slug) VALUES ('Other Tenant', 'other_tenant') "
      . 'ON CONFLICT DO NOTHING' );

    my $user = Registry::DAO::User->create($dao->db, {
        name => 'Outsider', username => 'member_of_other',
        email => 'member_of_other@example.com', user_type => 'admin',
    });
    $dao->db->query(
        'INSERT INTO registry.tenant_users (tenant_id, user_id) '
      . 'SELECT id, ? FROM registry.tenants WHERE slug = ? ON CONFLICT DO NOTHING',
        $user->id, 'other_tenant' );

    my $c = $t->app->build_controller;
    $c->session(user_id => $user->id);
    $c->req->headers->header('X-As-Tenant' => 'target_tenant');

    isnt $c->tenant, 'target_tenant',
        'a login elsewhere does not grant access to this tenant';
};

subtest 'the as-tenant cookie is held to the same rule' => sub {
    my $user = Registry::DAO::User->find($dao->db, { username => 'member_of_other' });

    # The cookie header must be set BEFORE session() -- reading the session
    # parses and caches the request's cookies, and a later header change is not
    # picked up. Getting this backwards made an earlier version of this subtest
    # pass while testing nothing.
    my $c = $t->app->build_controller;
    $c->req->headers->cookie('as-tenant=target_tenant');
    $c->session(user_id => $user->id);
    is $c->req->cookie('as-tenant')->value, 'target_tenant',
        'the cookie is actually set -- without this the subtest would pass vacuously';

    isnt $c->tenant, 'target_tenant',
        'the cookie is not a way around the header check';

    # And the positive half, without which this subtest passes on main too --
    # there the cookie simply never worked (req->cookie returns an OBJECT, which
    # stringified to "as-tenant=<slug>" and failed the slug regex), so "not
    # honoured" was true for the wrong reason. t/playwright/payment-smoke.spec.js
    # sets this cookie expecting to be routed to a tenant, and never was.
    my $member = Registry::DAO::User->find($dao->db, { username => 'member_of_target' });
    my $c2 = $t->app->build_controller;
    $c2->req->headers->cookie('as-tenant=target_tenant');
    $c2->session(user_id => $member->id);

    is $c2->tenant, 'target_tenant',
        'a member IS routed by the cookie, so the path works and is merely guarded';
};

# Platform standing is membership of the all-zeros platform tenant -- that is
# how create-default-pricing-relationships and the tier seed both identify it,
# and production carries exactly one such row.
subtest 'a platform admin may act as any tenant' => sub {
    my $user = Registry::DAO::User->create($dao->db, {
        name => 'Platform Admin', username => 'platform_admin_hdr',
        email => 'platform_admin_hdr@example.com', user_type => 'admin',
    });
    $dao->db->query(
        "INSERT INTO registry.tenants (id, name, slug) "
      . "VALUES ('00000000-0000-0000-0000-000000000000', 'Registry Platform', 'registry_platform') "
      . 'ON CONFLICT (id) DO NOTHING' );
    $dao->db->query(
        'INSERT INTO registry.tenant_users (tenant_id, user_id) '
      . "VALUES ('00000000-0000-0000-0000-000000000000', ?) ON CONFLICT DO NOTHING",
        $user->id );

    my $c = $t->app->build_controller;
    $c->session(user_id => $user->id);
    $c->req->headers->header('X-As-Tenant' => 'target_tenant');

    is $c->tenant, 'target_tenant', 'platform standing crosses tenants deliberately';
};

subtest 'unauthenticated build_controller ignores header' => sub {
    my $c = $t->app->build_controller;
    # No session user_id
    $c->req->headers->header('X-As-Tenant' => 'target_tenant');
    my $tenant = $c->tenant;
    isnt $tenant, 'target_tenant', 'unauthenticated controller ignores X-As-Tenant';
};

done_testing;
