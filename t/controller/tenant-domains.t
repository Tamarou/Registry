#!/usr/bin/env perl
# ABOUTME: Controller tests for the admin domain management interface.
# ABOUTME: Covers authorization, add/list/verify/set_primary/remove operations.
use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Fixtures;

use Registry::DAO::User;
use Registry::DAO::Tenant;
use Registry::DAO::TenantDomain;

my $tdb = Test::Registry::DB->new;
my $dao = $tdb->db;
$ENV{DB_URL} = $tdb->uri;

my $tenant = Test::Registry::Fixtures::create_tenant($dao->db, {
    name => 'Admin Domain Tenant',
    slug => 'admin_domain_tenant',
});

my $admin_user = Registry::DAO::User->create($dao->db, {
    username  => 'domain_admin',
    email     => 'domain_admin@example.com',
    name      => 'Domain Admin',
    user_type => 'admin',
});

my $staff_user = Registry::DAO::User->create($dao->db, {
    username  => 'domain_staff',
    email     => 'domain_staff@example.com',
    name      => 'Domain Staff',
    user_type => 'staff',
});

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $dao });

# current_user is swapped per-subtest via this reference.
# Using our() here allows `local` to temporarily override it within subtests.
our $active_user;

# Inject the render_service helper with a mock that captures calls
my @render_calls;
my $mock_render = bless {}, 'MockRenderService';
{
    no strict 'refs';
    *{'MockRenderService::add_custom_domain'} = sub {
        my ($self, $domain) = @_;
        push @render_calls, { action => 'add', domain => $domain };
        return { id => 'render-fake-id', name => $domain };
    };
    *{'MockRenderService::verify_custom_domain'} = sub {
        my ($self, $render_id) = @_;
        push @render_calls, { action => 'verify', render_id => $render_id };
        return { id => $render_id, verificationStatus => 'confirmed' };
    };
    *{'MockRenderService::remove_custom_domain'} = sub {
        my ($self, $render_id) = @_;
        push @render_calls, { action => 'remove', render_id => $render_id };
        return 1;
    };
}

$t->app->helper(render_service => sub { $mock_render });

# Inject tenant from Host header, and current_user from $active_user
$t->app->hook(around_dispatch => sub ($next, $c) {
    my $host = $c->req->headers->header('Host') // '';
    if ($host =~ /^([a-z0-9_]+)\./) {
        $c->stash(tenant => $1);
    }

    if ($active_user) {
        $c->stash(current_user => {
            id        => $active_user->id,
            username  => $active_user->username,
            name      => $active_user->name,
            email     => $active_user->email,
            user_type => $active_user->user_type,
            role      => $active_user->user_type,
            # api_key truthy skips CSRF validation
            api_key   => 1,
        });
    }

    $next->();
});

my $host_header = { Host => 'admin_domain_tenant.localhost' };

# ---------------------------------------------------------------------------
# Authorization tests
# ---------------------------------------------------------------------------

subtest 'Unauthenticated access redirected' => sub {
    local $active_user = undef;
    $t->get_ok('/admin/domains' => $host_header)
      ->status_is(302, 'Unauthenticated user redirected');
};

subtest 'Staff cannot access domain management' => sub {
    local $active_user = $staff_user;
    $t->get_ok('/admin/domains' => $host_header)
      ->status_is(403, 'Staff user rejected from domain management');
};

subtest 'Admin can list domains' => sub {
    local $active_user = $admin_user;
    $t->get_ok('/admin/domains' => $host_header)
      ->status_is(200, 'Admin can access domain list');
};

# ---------------------------------------------------------------------------
# Add domain tests
# ---------------------------------------------------------------------------

subtest 'Admin can add a valid domain' => sub {
    local $active_user = $admin_user;
    @render_calls = ();

    $t->post_ok('/admin/domains' => $host_header,
        form => { domain => 'new-domain.example.com' })
      ->status_isnt(422, 'Valid domain not rejected');

    my $td = Registry::DAO::TenantDomain->find_by_domain($dao->db, 'new-domain.example.com');
    ok($td, 'Domain row created in database');
    is($td->status, 'pending', 'New domain starts as pending');
    is(scalar(grep { $_->{action} eq 'add' } @render_calls), 1,
        'Render add_custom_domain was called');
};

subtest 'Add domain shows passkey re-registration warning' => sub {
    local $active_user = $admin_user;

    # First delete the domain from the previous subtest to avoid limit conflict,
    # then use a fresh domain for this test
    my $existing = Registry::DAO::TenantDomain->find_by_domain($dao->db, 'new-domain.example.com');
    $existing->remove($dao->db) if $existing;

    $t->post_ok('/admin/domains' => $host_header,
        form => { domain => 'passkey-warn.example.com' });
    $t->content_like(qr/passkey|re-register/i,
        'Response contains passkey re-registration warning');

    # Clean up
    my $td = Registry::DAO::TenantDomain->find_by_domain($dao->db, 'passkey-warn.example.com');
    $td->remove($dao->db) if $td;
};

subtest 'Add domain rejects invalid format' => sub {
    local $active_user = $admin_user;
    $t->post_ok('/admin/domains' => $host_header,
        form => { domain => 'not_a_domain' })
      ->status_is(422, 'Invalid domain format rejected');
};

subtest 'Add domain rejects tinyartempire.com subdomains' => sub {
    local $active_user = $admin_user;
    $t->post_ok('/admin/domains' => $host_header,
        form => { domain => 'sub.tinyartempire.com' })
      ->status_is(422, 'tinyartempire.com subdomain rejected');
};

subtest 'Add domain enforces 1-domain limit' => sub {
    local $active_user = $admin_user;

    # Ensure tenant has exactly one domain
    my @existing = Registry::DAO::TenantDomain->for_tenant($dao->db, $tenant->id);
    if (!@existing) {
        $dao->db->insert('tenant_domains', {
            tenant_id => $tenant->id,
            domain    => 'limit-test-existing.example.com',
            status    => 'pending',
        });
    }

    $t->post_ok('/admin/domains' => $host_header,
        form => { domain => 'second-domain.example.com' })
      ->status_is(422, '1-domain limit enforced by controller');
};

# ---------------------------------------------------------------------------
# Verify endpoint tests
# ---------------------------------------------------------------------------

subtest 'Trigger verification check' => sub {
    local $active_user = $admin_user;
    @render_calls = ();

    my $td = Registry::DAO::TenantDomain->find_by_domain($dao->db, 'limit-test-existing.example.com')
        // Registry::DAO::TenantDomain->find_by_domain($dao->db, 'new-domain.example.com');

    # Ensure we have a domain to work with
    unless ($td) {
        $dao->db->insert('tenant_domains', {
            tenant_id => $tenant->id,
            domain    => 'verify-test.example.com',
            status    => 'pending',
        });
        $td = Registry::DAO::TenantDomain->find_by_domain($dao->db, 'verify-test.example.com');
    }

    $t->post_ok("/admin/domains/@{[$td->id]}/verify" => $host_header)
      ->status_isnt(500, 'Verify endpoint reachable');
};

# ---------------------------------------------------------------------------
# Set primary domain tests
# ---------------------------------------------------------------------------

subtest 'Set primary domain' => sub {
    local $active_user = $admin_user;

    # Find or create a domain to make primary
    my ($td) = Registry::DAO::TenantDomain->for_tenant($dao->db, $tenant->id);
    unless ($td) {
        $dao->db->insert('tenant_domains', {
            tenant_id => $tenant->id,
            domain    => 'primary-test.example.com',
            status    => 'pending',
        });
        ($td) = Registry::DAO::TenantDomain->for_tenant($dao->db, $tenant->id);
    }

    # Mark verified first so it can become primary
    $td->mark_verified($dao->db);

    $t->post_ok("/admin/domains/@{[$td->id]}/primary" => $host_header)
      ->status_isnt(500, 'Set primary endpoint reachable');

    my $reloaded = Registry::DAO::TenantDomain->find($dao->db, { id => $td->id });
    is($reloaded->is_primary, 1, 'Domain marked as primary');

    my $t_reloaded = Registry::DAO::Tenant->find($dao->db, { id => $tenant->id });
    is($t_reloaded->canonical_domain, $td->domain,
        'Tenant canonical_domain updated after set_primary');
};

# ---------------------------------------------------------------------------
# Remove domain tests
# ---------------------------------------------------------------------------

subtest 'Remove a non-primary domain' => sub {
    local $active_user = $admin_user;

    my $extra = $dao->db->insert('tenant_domains', {
        tenant_id => $tenant->id,
        domain    => 'to-delete.example.com',
        status    => 'pending',
    }, { returning => '*' })->hash;

    # Clear canonical_domain so the redirect hook doesn't 301 us
    $dao->db->update('tenants', { canonical_domain => undef }, { id => $tenant->id });

    $t->delete_ok("/admin/domains/$extra->{id}" => $host_header)
      ->status_isnt(500, 'Remove endpoint reachable');

    my $gone = Registry::DAO::TenantDomain->find_by_domain($dao->db, 'to-delete.example.com');
    ok(!$gone, 'Domain row removed from database');
};

subtest 'Remove primary domain clears canonical_domain' => sub {
    local $active_user = $admin_user;

    # Find the primary domain for this tenant
    my ($primary_td) = grep { $_->is_primary }
        Registry::DAO::TenantDomain->for_tenant($dao->db, $tenant->id);

    unless ($primary_td) {
        # Create and mark as primary if none exists
        $dao->db->insert('tenant_domains', {
            tenant_id  => $tenant->id,
            domain     => 'primary-to-delete.example.com',
            status     => 'verified',
            is_primary => 1,
        });
        $dao->db->update('tenants',
            { canonical_domain => 'primary-to-delete.example.com' },
            { id => $tenant->id });
        ($primary_td) = grep { $_->is_primary }
            Registry::DAO::TenantDomain->for_tenant($dao->db, $tenant->id);
    }

    my $primary_domain = $primary_td->domain;

    # Use the canonical domain as Host so the redirect hook doesn't 301 us
    $t->delete_ok("/admin/domains/@{[$primary_td->id]}" => { Host => $primary_domain })
      ->status_isnt(500, 'Remove primary domain endpoint reachable');

    my $t_reloaded = Registry::DAO::Tenant->find($dao->db, { id => $tenant->id });
    is($t_reloaded->canonical_domain, undef,
        'canonical_domain cleared after removing primary domain');
};

done_testing();
