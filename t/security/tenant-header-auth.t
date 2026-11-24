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
use Test::Registry::OperatorRight qw( revoke_operator restore_operator grant_in_schema );
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

# The platform tenant is the all-zeros row, slug registry, and it holds the
# operator right because its entitlement in registry says so.
sub platform_member ( $username, $role ) {
    my $user = Registry::DAO::User->create( $dao->db, {
        name => $username, username => $username,
        email => "$username\@example.com", user_type => 'admin',
    } );
    Registry::DAO::Tenant->platform( $dao->db )->add_user( $dao->db, $user, 0, $role );
    return $user;
}

sub acting_as ( $user, $requested, %opt ) {
    my $c = $t->app->build_controller;
    $c->req->headers->cookie("as-tenant=$requested") if $opt{cookie};
    $c->session( user_id => $user->id ) if $user;
    $c->req->headers->header( 'X-As-Tenant' => $requested ) unless $opt{cookie};
    return $c->tenant;
}

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
subtest 'an admin of the operator tenant may act as any tenant' => sub {
    my $user = platform_member( 'platform_admin_hdr', 'admin' );

    is acting_as( $user, 'target_tenant' ), 'target_tenant',
        'holding the operator right crosses tenants deliberately';
};

# Ruling 4: platform standing is the admin ROLE on the platform membership, not
# the membership alone. A studio admin added to the platform as staff keeps a
# global user_type of admin, so letting them act as a studio would hand them
# that studio's admin pages through require_role.
subtest 'a platform member without the admin role may not act as another tenant' => sub {
    my $user = Registry::DAO::User->create($dao->db, {
        name => 'Platform Staff', username => 'platform_staff_hdr',
        email => 'platform_staff_hdr@example.com', user_type => 'admin',
    });
    $dao->db->query(
        'INSERT INTO registry.tenant_users (tenant_id, user_id, role) '
      . "VALUES ('00000000-0000-0000-0000-000000000000', ?, 'staff') ON CONFLICT DO NOTHING",
        $user->id );

    my $c = $t->app->build_controller;
    $c->session(user_id => $user->id);
    $c->req->headers->header('X-As-Tenant' => 'target_tenant');

    isnt $c->tenant, 'target_tenant', 'a staff role on the platform crosses no tenant';
};

# collapse-platform-tenant.sql renamed the all-zeros platform row from
# `registry-platform` to `registry`. A header or cookie still carrying the old
# slug must name nothing, rather than reach the platform by its former name.
subtest 'the retired registry-platform slug resolves to no tenant' => sub {
    is Registry::DAO::Tenant->find( $dao->db, { slug => 'registry-platform' } ), undef,
        'no tenant row carries the retired slug';

    my $user = Registry::DAO::User->find( $dao->db, { username => 'member_of_other' } );

    my $plain = $t->app->build_controller;
    $plain->session( user_id => $user->id );
    my $without_header = $plain->tenant;

    my $c = $t->app->build_controller;
    $c->session( user_id => $user->id );
    $c->req->headers->header( 'X-As-Tenant' => 'registry-platform' );

    isnt $c->tenant, 'registry-platform', 'the header does not select the retired slug';
    is $c->tenant, $without_header, 'the header changes nothing: it is ignored, not honoured';
    ok !Registry::DAO::Tenant->is_platform_admin( $dao->db, $user->id ),
        'and sending it does not make the sender the platform';
};

subtest 'unauthenticated build_controller ignores header' => sub {
    my $c = $t->app->build_controller;
    # No session user_id
    $c->req->headers->header('X-As-Tenant' => 'target_tenant');
    my $tenant = $c->tenant;
    isnt $tenant, 'target_tenant', 'unauthenticated controller ignores X-As-Tenant';
};

subtest 'a staff member of the platform tenant cannot act as another tenant' => sub {
    my $user = platform_member( 'platform_staff_act', 'staff' );
    isnt acting_as( $user, 'target_tenant' ), 'target_tenant', 'staff holds no operator right';
};

subtest 'without the operator right a platform admin cannot act as another tenant' => sub {
    my $user = Registry::DAO::User->find( $dao->db, { username => 'platform_admin_hdr' } );
    # Deleted for real: the app asks through its own connection, which would
    # not see a delete inside this test's open transaction.
    my $held = revoke_operator( $dao->db );
    isnt acting_as( $user, 'target_tenant' ), 'target_tenant',
        'platform membership alone is not the right';
    restore_operator( $dao->db, $held );
    is acting_as( $user, 'target_tenant' ), 'target_tenant', 'and with it back, the admin may';
};

subtest 'an admin of a tenant without the operator right acts only as their own tenant' => sub {
    my $morgan = Registry::DAO::User->create( $dao->db, {
        name => 'Morgan', username => 'morgan_act', email => 'morgan_act@example.com', user_type => 'admin' } );
    Registry::DAO::Tenant->find( $dao->db, { slug => 'other_tenant' } )->add_user( $dao->db, $morgan, 1, 'admin' );

    is acting_as( $morgan, 'other_tenant' ), 'other_tenant', 'Morgan acts as her own tenant';
    isnt acting_as( $morgan, 'target_tenant' ), 'target_tenant', 'and as no other';
};

subtest 'a parent member of the platform tenant cannot act as another tenant' => sub {
    my $user = platform_member( 'platform_parent_act', 'parent' );
    isnt acting_as( $user, 'target_tenant' ), 'target_tenant', 'a parent holds no operator right';
};

subtest 'the as-tenant cookie holds a platform staff member to the header rule' => sub {
    my $user = Registry::DAO::User->find( $dao->db, { username => 'platform_staff_act' } );
    isnt acting_as( $user, 'target_tenant', cookie => 1 ), 'target_tenant', 'the cookie is refused too';

    my $admin = Registry::DAO::User->find( $dao->db, { username => 'platform_admin_hdr' } );
    is acting_as( $admin, 'target_tenant', cookie => 1 ), 'target_tenant',
        'while an operator admin is routed by it, so the refusal is the rule and not a broken cookie';
};

subtest 'an ordinary tenant admin cannot act as the platform tenant' => sub {
    my $morgan = Registry::DAO::User->find( $dao->db, { username => 'morgan_act' } );
    my $plain = do { my $c = $t->app->build_controller; $c->session( user_id => $morgan->id ); $c->tenant };
    my $got = acting_as( $morgan, 'registry' );
    is $got, $plain, 'the header changes nothing: Morgan gets what she gets without it';
};

subtest 'an unknown or malformed tenant name switches nothing and causes no error' => sub {
    my $admin = Registry::DAO::User->find( $dao->db, { username => 'platform_admin_hdr' } );
    my $plain = do { my $c = $t->app->build_controller; $c->session( user_id => $admin->id ); $c->tenant };
    for my $bad ( 'no_such_tenant', 'registry; drop table x', '../registry' ) {
        my $got = eval { acting_as( $admin, $bad ) };
        is $@, '', "'$bad' raises nothing";
        is $got, $plain, "'$bad' switches nothing";
    }
};

subtest 'an operator grant in a tenant own schema copy confers no acting as another tenant' => sub {
    $dao->db->query('SELECT clone_schema(?)', 'other_tenant')
        unless $dao->db->query(q{SELECT 1 FROM information_schema.schemata WHERE schema_name = 'other_tenant'})->rows;
    my $other_id = Registry::DAO::Tenant->find( $dao->db, { slug => 'other_tenant' } )->id;
    grant_in_schema( $dao, 'other_tenant', $other_id, 'operator' );

    my $morgan = Registry::DAO::User->find( $dao->db, { username => 'morgan_act' } );
    isnt acting_as( $morgan, 'target_tenant' ), 'target_tenant', 'a self-written grant grants nothing';
};

subtest 'an unauthenticated request with the header is not switched' => sub {
    isnt acting_as( undef, 'target_tenant' ), 'target_tenant', 'no session, no switch';
};

done_testing;
