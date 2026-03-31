# Custom Domains Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable tenants to bring their own domains (e.g., `dance-stars.com`) with automatic HTTPS via Render, replacing the default `<slug>.tinyartempire.com` subdomain. Includes tenant resolution via custom domain, 301 redirect to canonical domain, self-service domain management, and background DNS verification.

**Architecture:** A `tenant_domains` table in the `registry` schema maps custom domains to tenants. The existing `tenant` helper gains a custom-domain lookup step. A `before_dispatch` hook redirects non-canonical requests with 301. Render's Custom Domains API handles TLS provisioning. Domain management is admin-only via `/admin/domains` routes.

**Tech Stack:** Perl 5.42, Object::Pad, Mojolicious, Mojo::UserAgent (Render API), PostgreSQL, Sqitch, Minion (background verification)

**Spec:** `docs/specs/custom-domains.md`

---

## File Structure

### New Files

**Database Migration (Sqitch triple):**
- `sql/deploy/tenant-domains.sql` — `tenant_domains` table in registry schema
- `sql/revert/tenant-domains.sql` — drop table
- `sql/verify/tenant-domains.sql` — verify table exists

**DAO:**
- `lib/Registry/DAO/TenantDomain.pm` — CRUD, find_by_domain, set_primary, mark_verified, remove, domain validation

**Render API Client:**
- `lib/Registry/Service/Render.pm` — add/verify/remove custom domains via Render API

**Controller:**
- `lib/Registry/Controller/TenantDomains.pm` — admin CRUD for domain management

**Templates:**
- `templates/admin/domains/index.html.ep` — domain list with status indicators
- `templates/admin/domains/dns_instructions.html.ep` — DNS record instructions

**Background Job:**
- `lib/Registry/Job/DomainVerification.pm` — periodic verification of pending domains

**Tests:**
- `t/dao/tenant-domain.t` — DAO unit tests
- `t/service/render-api.t` — Render API client with injected test UA
- `t/controller/tenant-domains.t` — admin controller tests
- `t/integration/custom-domain-resolution.t` — tenant resolution and redirect tests
- `t/job/domain-verification.t` — background job tests

### Modified Files

- `lib/Registry.pm` — add custom domain lookup to tenant helper, add canonical domain redirect hook, register domain management routes, register background job
- `lib/Registry/DAO/Tenant.pm` — add method to update canonical_domain
- `lib/Registry/Email/Template.pm` — add domain_verified and domain_verification_failed templates

---

## Milestone 1: Canonical Domain Redirect (Minimal)

Uses the existing `canonical_domain` column on tenants. No `tenant_domains` table, no Render API. Tenants set canonical_domain manually (or via admin API). The redirect works immediately for any tenant with the field set.

---

## Task 1: Canonical Domain Redirect Hook

> **Requires:** The `canonical_domain` field on `tenants` (already deployed in passwordless-auth migration).

**Files:**
- Modify: `lib/Registry.pm` (add before_dispatch hook)
- Create: `t/integration/custom-domain-resolution.t`

- [ ] **Step 1: Write the failing test**

Create `t/integration/custom-domain-resolution.t`. Use the `$ENV{DB_URL} = $tdb->uri` pattern (matching `t/controller/location.t` and other controller tests) so the app's `dao` helper automatically connects to the test database. Do not override the `dao` helper directly.

```perl
#!/usr/bin/env perl
# ABOUTME: Integration tests for canonical domain redirect and custom domain
# ABOUTME: tenant resolution. Validates 301 redirect, path preservation, and fallback.
use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Mojo;
use Test::Registry::DB;
use Test::Registry::Fixtures;

my $tdb = Test::Registry::DB->new;
my $dao = $tdb->db;
$ENV{DB_URL} = $tdb->uri;

# Create a tenant with a canonical domain set
my $tenant = Test::Registry::Fixtures::create_tenant($dao, {
    name => 'Dance Stars',
    slug => 'dance_stars',
});
$dao->db->update('tenants',
    { canonical_domain => 'dance-stars.com' },
    { id => $tenant->id }
);

my $t = Test::Mojo->new('Registry');

subtest 'Request on non-canonical domain redirects to canonical' => sub {
    # Simulate request arriving on the subdomain when canonical domain is set.
    # Host comparison is case-insensitive (domains are case-insensitive per RFC 1035).
    $t->get_ok('/auth/login' => { Host => 'dance_stars.localhost' })
      ->status_is(301, 'Non-canonical domain returns 301')
      ->header_like(Location => qr{^https?://dance-stars\.com/auth/login},
        'Redirects to canonical domain with same path');
};

subtest 'Request on canonical domain does not redirect' => sub {
    $t->get_ok('/auth/login' => { Host => 'dance-stars.com' })
      ->status_isnt(301, 'Canonical domain does not redirect');
};

subtest 'Redirect preserves query string' => sub {
    $t->get_ok('/workflow/enrollment?session=abc' => { Host => 'dance_stars.localhost' })
      ->status_is(301)
      ->header_like(Location => qr{dance-stars\.com/workflow/enrollment\?session=abc},
        'Query string preserved in redirect');
};

subtest 'Tenant without canonical domain does not redirect' => sub {
    my $plain = Test::Registry::Fixtures::create_tenant($dao, {
        name => 'Plain Tenant',
        slug => 'plain_tenant',
    });
    $t->get_ok('/auth/login' => { Host => 'plain_tenant.localhost' })
      ->status_isnt(301, 'No redirect when canonical_domain is not set');
};

subtest 'Webhooks are not redirected' => sub {
    $t->post_ok('/webhooks/stripe' => { Host => 'dance_stars.localhost' },
        json => { type => 'test' })
      ->status_isnt(301, 'Webhook requests skip canonical redirect');
};

subtest 'Static assets are not redirected' => sub {
    $t->get_ok('/assets/app.css' => { Host => 'dance_stars.localhost' })
      ->status_isnt(301, 'Static asset requests skip canonical redirect');
};

subtest 'Redirect loop is prevented when host already matches canonical' => sub {
    # Even if canonical_domain contains the same value as the request host,
    # there must be no redirect (guards against misconfigured duplicate entries).
    $t->get_ok('/auth/login' => { Host => 'dance-stars.com' })
      ->status_isnt(301, 'No redirect loop when host equals canonical_domain');
};

done_testing();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `carton exec prove -lv t/integration/custom-domain-resolution.t`
Expected: FAIL — no redirect hook exists yet

- [ ] **Step 3: Add canonical domain redirect hook to Registry.pm**

Add a new `before_dispatch` hook after the rate limiter hook. This hook:
1. Skips webhooks, health checks, static assets, and any path under `/assets`
2. Resolves the tenant
3. Looks up the tenant's `canonical_domain`
4. Compares host case-insensitively (domains are case-insensitive per RFC 1035)
5. If set and different from the request Host, 301 redirects

Note: the per-request DB query is an accepted trade-off documented in the spec: "An index on `tenant_domains.domain` keeps this sub-millisecond. Optimize with caching later if needed." The same reasoning applies to the `canonical_domain` field lookup here.

```perl
# Canonical domain redirect: if the tenant has a canonical domain and the
# request arrived on a different host, redirect with 301. The per-request
# DB query is an accepted trade-off (see spec); the index keeps it fast.
$self->hook(
    before_dispatch => sub ($c) {
        my $path = $c->req->url->path;

        # Skip webhook, health check, and static asset paths
        return if $path =~ m{^/(webhooks|health|assets)};

        my $host = lc($c->req->url->to_abs->host // '');
        return unless $host;

        # Resolve tenant and check for canonical domain
        my $tenant_slug = $c->tenant;
        return if $tenant_slug eq 'registry';

        try {
            my $dao = $c->dao($tenant_slug);
            my $tenant = Registry::DAO::Tenant->find($dao->db, { slug => $tenant_slug });
            return unless $tenant && $tenant->canonical_domain;

            my $canonical = lc($tenant->canonical_domain);

            # Skip if already on the canonical domain (prevents redirect loops)
            return if $host eq $canonical;

            # Build redirect URL preserving path and query
            my $redirect = $c->req->url->to_abs->clone;
            $redirect->host($canonical);
            $c->res->headers->location($redirect->to_string);
            $c->rendered(301);
        }
        catch ($e) {
            $c->app->log->warn("Canonical domain redirect failed: $e");
        }
    }
);
```

- [ ] **Step 4: Run test to verify it passes**

Run: `carton exec prove -lv t/integration/custom-domain-resolution.t`
Expected: PASS

- [ ] **Step 5: Run broader regression tests**

Run: `carton exec prove -lr t/controller/ t/integration/ t/security/`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add lib/Registry.pm t/integration/custom-domain-resolution.t
git commit -m "Add canonical domain 301 redirect hook"
```

---

## Task 2: Tenant.pm — update_canonical_domain Method

**Files:**
- Modify: `lib/Registry/DAO/Tenant.pm`
- Create or modify: `t/dao/tenant.t` (or whichever file covers Tenant DAO)

- [ ] **Step 0: Write the failing test first (TDD)**

Add a test case for `update_canonical_domain` to the existing Tenant DAO test file before writing any implementation. Run the test to confirm it fails:

```perl
subtest 'update_canonical_domain sets the canonical domain' => sub {
    my $tenant = Test::Registry::Fixtures::create_tenant($dao, {
        name => 'Domain Tenant',
        slug => 'domain_tenant',
    });

    $tenant->update_canonical_domain($dao->db, 'example.com');

    my $reloaded = Registry::DAO::Tenant->find($dao->db, { id => $tenant->id });
    is($reloaded->canonical_domain, 'example.com',
        'canonical_domain updated correctly');

    # Clear it again
    $tenant->update_canonical_domain($dao->db, undef);
    $reloaded = Registry::DAO::Tenant->find($dao->db, { id => $tenant->id });
    is($reloaded->canonical_domain, undef, 'canonical_domain cleared correctly');
};
```

Run: `carton exec prove -lv t/dao/tenant*.t`
Expected: FAIL — method does not exist yet

- [ ] **Step 1: Add the method**

```perl
method update_canonical_domain ($db, $domain) {
    $db = $db->db if $db isa Registry::DAO;
    return $self->update($db, { canonical_domain => $domain });
}
```

- [ ] **Step 2: Verify tests pass**

Run: `carton exec prove -lv t/dao/tenant*.t t/controller/tenant*.t`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add lib/Registry/DAO/Tenant.pm t/dao/tenant.t
git commit -m "Add update_canonical_domain method to Tenant DAO"
```

---

## Milestone 2: Full Custom Domains

Adds the `tenant_domains` table, Render API integration, admin UI, and background verification.

---

## Task 3: Database Migration — tenant_domains Table

**Files:**
- Create: `sql/deploy/tenant-domains.sql`
- Create: `sql/revert/tenant-domains.sql`
- Create: `sql/verify/tenant-domains.sql`
- Modify: `sql/sqitch.plan`

- [ ] **Step 1: Add migration to sqitch.plan**

Run: `carton exec sqitch add tenant-domains --requires notifications-and-preferences --note "Custom domain management for tenants"`

- [ ] **Step 2: Write deploy migration**

Write `sql/deploy/tenant-domains.sql`:

```sql
-- Deploy registry:tenant-domains to pg
-- requires: notifications-and-preferences

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

CREATE TABLE IF NOT EXISTS tenant_domains (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    domain text NOT NULL UNIQUE,
    status text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'verified', 'failed')),
    is_primary boolean NOT NULL DEFAULT false,
    render_domain_id text,
    verification_error text,
    verified_at timestamptz,
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now()
);

CREATE INDEX idx_tenant_domains_domain ON tenant_domains(domain);
CREATE INDEX idx_tenant_domains_tenant_id ON tenant_domains(tenant_id);

-- At most one primary domain per tenant
CREATE UNIQUE INDEX idx_tenant_domains_primary
    ON tenant_domains(tenant_id) WHERE is_primary = true;

-- Keep updated_at current on every row change
CREATE OR REPLACE FUNCTION registry.tenant_domains_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER tenant_domains_updated_at
    BEFORE UPDATE ON tenant_domains
    FOR EACH ROW EXECUTE FUNCTION registry.tenant_domains_updated_at();

COMMIT;
```

- [ ] **Step 3: Write revert migration**

```sql
-- Revert registry:tenant-domains from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

DROP TABLE IF EXISTS tenant_domains CASCADE;
DROP FUNCTION IF EXISTS registry.tenant_domains_updated_at();

COMMIT;
```

- [ ] **Step 4: Write verify migration**

```sql
-- Verify registry:tenant-domains on pg

BEGIN;

SET search_path TO registry, public;

SELECT id, tenant_id, domain, status, is_primary, render_domain_id,
       verification_error, verified_at, created_at, updated_at
  FROM tenant_domains WHERE FALSE;

ROLLBACK;
```

- [ ] **Step 5: Deploy and verify**

Run: `carton exec sqitch deploy && carton exec sqitch verify`

- [ ] **Step 6: Commit**

```bash
git add sql/deploy/tenant-domains.sql sql/revert/tenant-domains.sql sql/verify/tenant-domains.sql sql/sqitch.plan
git commit -m "Add tenant_domains table for custom domain management"
```

---

## Task 4: DAO — Registry::DAO::TenantDomain

**Files:**
- Create: `lib/Registry/DAO/TenantDomain.pm`
- Create: `t/dao/tenant-domain.t`

**Note on parent class:** The spec lists `Registry::DAO::Base` as the parent, but that is a typo in the spec. The correct parent class used throughout the codebase is `Registry::DAO::Object`. Use `Registry::DAO::Object`.

- [ ] **Step 1: Write the failing test**

Create `t/dao/tenant-domain.t`. The test must cover:
- CRUD operations
- `find_by_domain` lookup
- `for_tenant` lists all rows for a tenant (no limit enforcement — limit is the controller's responsibility)
- `set_primary` marks one domain as primary, clears any previous primary, and also calls `update_canonical_domain` on the owning tenant
- `mark_verified` updates status/verified_at, and also calls `update_canonical_domain` if `is_primary` is true
- `remove` deletes the row and calls `update_canonical_domain(undef)` on the tenant when the removed domain was primary
- Domain format validation (reject IPs, localhost, tinyartempire.com subdomains)
- Cascade delete when tenant is deleted
- Uniqueness constraint (same domain can't belong to two tenants)
- Transition tests: set_primary → tenants.canonical_domain updated; mark_verified when is_primary → tenants.canonical_domain updated; remove when is_primary → tenants.canonical_domain cleared

```perl
#!/usr/bin/env perl
# ABOUTME: Unit tests for Registry::DAO::TenantDomain. Covers CRUD, domain
# ABOUTME: validation, primary transitions, and canonical_domain side-effects.
use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;

use Registry::DAO::TenantDomain;
use Registry::DAO::Tenant;

my $tdb = Test::Registry::DB->new;
my $dao = $tdb->db;
my $db  = $dao->db;

my $tenant = Test::Registry::Fixtures::create_tenant($dao, {
    name => 'Domain Test Tenant',
    slug => 'domain_test_tenant',
});

subtest 'CRUD operations' => sub {
    my $td = Registry::DAO::TenantDomain->create($db, {
        tenant_id => $tenant->id,
        domain    => 'example.com',
        status    => 'pending',
    });
    ok($td, 'domain row created');
    is($td->domain, 'example.com', 'domain field correct');
    is($td->status, 'pending',     'status defaults to pending');
    is($td->is_primary, 0,         'is_primary defaults to false');

    my $found = Registry::DAO::TenantDomain->find($db, { id => $td->id });
    ok($found, 'find by id');
    is($found->domain, 'example.com', 'find returns correct row');

    $db->delete('tenant_domains', { id => $td->id });
};

subtest 'find_by_domain' => sub {
    my $td = Registry::DAO::TenantDomain->create($db, {
        tenant_id => $tenant->id,
        domain    => 'findme.example.com',
        status    => 'verified',
    });

    my $found = Registry::DAO::TenantDomain->find_by_domain($db, 'findme.example.com');
    ok($found, 'found by domain name');
    is($found->tenant_id, $tenant->id, 'belongs to correct tenant');

    my $missing = Registry::DAO::TenantDomain->find_by_domain($db, 'nothere.example.com');
    ok(!$missing, 'returns undef for unknown domain');

    $db->delete('tenant_domains', { id => $td->id });
};

subtest 'for_tenant returns all rows (no limit enforcement)' => sub {
    my $td1 = Registry::DAO::TenantDomain->create($db, {
        tenant_id => $tenant->id,
        domain    => 'first.example.com',
    });
    my $td2 = Registry::DAO::TenantDomain->create($db, {
        tenant_id => $tenant->id,
        domain    => 'second.example.com',
    });

    my @domains = Registry::DAO::TenantDomain->for_tenant($db, $tenant->id);
    is(scalar @domains, 2, 'for_tenant returns all rows');

    $db->delete('tenant_domains', { tenant_id => $tenant->id });
};

subtest 'set_primary updates tenant canonical_domain' => sub {
    my $td = Registry::DAO::TenantDomain->create($db, {
        tenant_id => $tenant->id,
        domain    => 'primary.example.com',
        status    => 'verified',
    });

    $td->set_primary($db);
    is($td->is_primary, 1, 'is_primary set to true on the domain row');

    my $reloaded_tenant = Registry::DAO::Tenant->find($db, { id => $tenant->id });
    is($reloaded_tenant->canonical_domain, 'primary.example.com',
        'set_primary also updates tenants.canonical_domain');

    # A second set_primary clears the first
    my $td2 = Registry::DAO::TenantDomain->create($db, {
        tenant_id => $tenant->id,
        domain    => 'other.example.com',
        status    => 'verified',
    });
    $td2->set_primary($db);

    my $reloaded_first = Registry::DAO::TenantDomain->find($db, { id => $td->id });
    is($reloaded_first->is_primary, 0, 'previous primary cleared');

    my $reloaded_tenant2 = Registry::DAO::Tenant->find($db, { id => $tenant->id });
    is($reloaded_tenant2->canonical_domain, 'other.example.com',
        'canonical_domain updated to new primary');

    $db->delete('tenant_domains', { tenant_id => $tenant->id });
    $db->update('tenants', { canonical_domain => undef }, { id => $tenant->id });
};

subtest 'mark_verified updates canonical_domain when is_primary' => sub {
    my $td = Registry::DAO::TenantDomain->create($db, {
        tenant_id  => $tenant->id,
        domain     => 'verify-primary.example.com',
        status     => 'pending',
        is_primary => 1,
    });

    $td->mark_verified($db);
    is($td->status, 'verified', 'status updated to verified');
    ok($td->verified_at, 'verified_at timestamp set');

    my $reloaded_tenant = Registry::DAO::Tenant->find($db, { id => $tenant->id });
    is($reloaded_tenant->canonical_domain, 'verify-primary.example.com',
        'mark_verified updates canonical_domain when domain is_primary');

    $db->delete('tenant_domains', { id => $td->id });
    $db->update('tenants', { canonical_domain => undef }, { id => $tenant->id });
};

subtest 'mark_verified does not change canonical_domain when not primary' => sub {
    my $td = Registry::DAO::TenantDomain->create($db, {
        tenant_id  => $tenant->id,
        domain     => 'verify-nonprimary.example.com',
        status     => 'pending',
        is_primary => 0,
    });

    $td->mark_verified($db);
    is($td->status, 'verified', 'status updated to verified');

    my $reloaded_tenant = Registry::DAO::Tenant->find($db, { id => $tenant->id });
    is($reloaded_tenant->canonical_domain, undef,
        'canonical_domain unchanged when non-primary domain is verified');

    $db->delete('tenant_domains', { id => $td->id });
};

subtest 'remove clears canonical_domain when removing primary' => sub {
    my $td = Registry::DAO::TenantDomain->create($db, {
        tenant_id  => $tenant->id,
        domain     => 'to-remove.example.com',
        status     => 'verified',
        is_primary => 1,
    });
    $db->update('tenants', { canonical_domain => 'to-remove.example.com' },
        { id => $tenant->id });

    $td->remove($db);

    my $gone = Registry::DAO::TenantDomain->find($db, { id => $td->id });
    ok(!$gone, 'row deleted');

    my $reloaded_tenant = Registry::DAO::Tenant->find($db, { id => $tenant->id });
    is($reloaded_tenant->canonical_domain, undef,
        'remove clears canonical_domain when primary domain is removed');
};

subtest 'remove does not clear canonical_domain for non-primary' => sub {
    $db->update('tenants', { canonical_domain => 'keeper.example.com' }, { id => $tenant->id });

    my $td = Registry::DAO::TenantDomain->create($db, {
        tenant_id  => $tenant->id,
        domain     => 'non-primary-remove.example.com',
        status     => 'verified',
        is_primary => 0,
    });

    $td->remove($db);

    my $reloaded_tenant = Registry::DAO::Tenant->find($db, { id => $tenant->id });
    is($reloaded_tenant->canonical_domain, 'keeper.example.com',
        'removing a non-primary domain leaves canonical_domain unchanged');

    $db->update('tenants', { canonical_domain => undef }, { id => $tenant->id });
};

subtest 'mark_failed records error' => sub {
    my $td = Registry::DAO::TenantDomain->create($db, {
        tenant_id => $tenant->id,
        domain    => 'fail.example.com',
        status    => 'pending',
    });

    $td->mark_failed($db, 'CNAME record not found');
    is($td->status, 'failed', 'status set to failed');
    is($td->verification_error, 'CNAME record not found', 'error stored');

    $db->delete('tenant_domains', { id => $td->id });
};

subtest 'domain format validation' => sub {
    my @valid = qw(example.com www.example.com sub.domain.example.com);
    my @invalid = (
        '192.168.1.1',
        'localhost',
        'dance.tinyartempire.com',
        '',
        'not_a_domain',
    );

    for my $d (@valid) {
        my $err = Registry::DAO::TenantDomain->validate_domain($d);
        ok(!$err, "valid domain accepted: $d");
    }
    for my $d (@invalid) {
        my $err = Registry::DAO::TenantDomain->validate_domain($d);
        ok($err, "invalid domain rejected: $d");
    }
};

subtest 'uniqueness constraint' => sub {
    my $other_tenant = Test::Registry::Fixtures::create_tenant($dao, {
        name => 'Other Tenant',
        slug => 'other_unique_tenant',
    });

    Registry::DAO::TenantDomain->create($db, {
        tenant_id => $tenant->id,
        domain    => 'unique.example.com',
    });

    eval {
        Registry::DAO::TenantDomain->create($db, {
            tenant_id => $other_tenant->id,
            domain    => 'unique.example.com',
        });
    };
    ok($@, 'duplicate domain rejected by uniqueness constraint');

    $db->delete('tenant_domains', { tenant_id => $tenant->id });
};

subtest 'cascade delete with tenant' => sub {
    my $temp_tenant = Test::Registry::Fixtures::create_tenant($dao, {
        name => 'Temp Tenant',
        slug => 'temp_cascade_tenant',
    });
    Registry::DAO::TenantDomain->create($db, {
        tenant_id => $temp_tenant->id,
        domain    => 'cascade.example.com',
    });

    $db->delete('tenants', { id => $temp_tenant->id });

    my $gone = Registry::DAO::TenantDomain->find_by_domain($db, 'cascade.example.com');
    ok(!$gone, 'domain row deleted when tenant is deleted');
};

done_testing();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `carton exec prove -lv t/dao/tenant-domain.t`
Expected: FAIL — module does not exist

- [ ] **Step 3: Write implementation**

Create `lib/Registry/DAO/TenantDomain.pm`:

```perl
# ABOUTME: DAO for tenant custom domains. Manages domain-to-tenant mapping,
# ABOUTME: verification status, primary domain selection, and domain validation.
use 5.42.0;
use Object::Pad;

class Registry::DAO::TenantDomain :isa(Registry::DAO::Object) {
    use Carp qw(croak);

    field $id :param :reader;
    field $tenant_id :param :reader;
    field $domain :param :reader;
    field $status :param :reader = 'pending';
    field $is_primary :param :reader = 0;
    field $render_domain_id :param :reader = undef;
    field $verification_error :param :reader = undef;
    field $verified_at :param :reader = undef;
    field $created_at :param :reader = undef;
    field $updated_at :param :reader = undef;

    sub table { 'tenant_domains' }

    sub find_by_domain ($class, $db, $domain) {
        $db = $db->db if $db isa Registry::DAO;
        my $row = $db->select('tenant_domains', '*', { domain => $domain })->hash;
        return $row ? $class->new(%$row) : undef;
    }

    # Returns all domain rows for a tenant. The 1-domain business limit is
    # enforced by the controller, not here. This method returns all rows so
    # future expansion (multiple domains) does not require a DAO change.
    sub for_tenant ($class, $db, $tenant_id) {
        $db = $db->db if $db isa Registry::DAO;
        my @rows = $db->select('tenant_domains', '*', { tenant_id => $tenant_id },
            { -asc => 'created_at' })->hashes->each;
        return map { $class->new(%$_) } @rows;
    }

    sub validate_domain ($class, $domain) {
        return 'Domain is required' unless $domain;
        return 'Invalid domain format'
            unless $domain =~ /\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+\z/i;
        return 'Cannot use IP addresses' if $domain =~ /\A\d+\.\d+\.\d+\.\d+\z/;
        return 'Cannot use localhost' if $domain =~ /\blocalhost\b/i;
        return 'Subdomains of tinyartempire.com are managed automatically'
            if $domain =~ /\.tinyartempire\.com\z/i;
        return undef;  # valid
    }

    # Mark this domain as primary for the tenant. Clears any previous primary
    # and updates tenants.canonical_domain to this domain's name.
    method set_primary ($db) {
        $db = $db->db if $db isa Registry::DAO;

        $db->update('tenant_domains',
            { is_primary => 0 },
            { tenant_id => $tenant_id, is_primary => 1 }
        );

        $self->update($db, { is_primary => 1 });

        require Registry::DAO::Tenant;
        my $tenant = Registry::DAO::Tenant->find($db, { id => $tenant_id });
        $tenant->update_canonical_domain($db, $domain) if $tenant;

        return $self;
    }

    # Mark domain as verified. If it is also primary, updates
    # tenants.canonical_domain to reflect the now-active domain.
    method mark_verified ($db) {
        $db = $db->db if $db isa Registry::DAO;
        $self->update($db, {
            status             => 'verified',
            verified_at        => \'now()',
            verification_error => undef,
        });

        if ($is_primary) {
            require Registry::DAO::Tenant;
            my $tenant = Registry::DAO::Tenant->find($db, { id => $tenant_id });
            $tenant->update_canonical_domain($db, $domain) if $tenant;
        }

        return $self;
    }

    method mark_failed ($db, $error) {
        $db = $db->db if $db isa Registry::DAO;
        return $self->update($db, {
            status             => 'failed',
            verification_error => $error,
        });
    }

    # Remove this domain record. If it was the primary domain, clears
    # tenants.canonical_domain so the tenant reverts to its default subdomain.
    method remove ($db) {
        $db = $db->db if $db isa Registry::DAO;

        if ($is_primary) {
            require Registry::DAO::Tenant;
            my $tenant = Registry::DAO::Tenant->find($db, { id => $tenant_id });
            $tenant->update_canonical_domain($db, undef) if $tenant;
        }

        $db->delete('tenant_domains', { id => $id });
        return 1;
    }
}

1;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `carton exec prove -lv t/dao/tenant-domain.t`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/Registry/DAO/TenantDomain.pm t/dao/tenant-domain.t
git commit -m "Add TenantDomain DAO with primary transitions and canonical_domain side-effects"
```

---

## Task 5: Render API Client — Registry::Service::Render

**Files:**
- Create: `lib/Registry/Service/Render.pm`
- Create: `t/service/render-api.t`

**Design note (sync vs async):** Render API calls are synchronous/blocking, matching the existing `Registry::Service::Stripe` pattern. Admin dashboard actions are low-frequency and user-initiated, so blocking is acceptable. Background verification (Task 9) uses Minion to keep the HTTP call off the request path. This is the same trade-off made in the Stripe integration.

**Testing pattern:** `Registry::Service::Render` accepts a `ua` field at construction time. Tests inject a `Mojo::UserAgent` subclass or a hand-rolled object that implements `post`, `get`, and `delete` methods returning canned `Mojo::Transaction` objects. This keeps the "no mocks for internal behavior" rule intact — the mock replaces the external HTTP boundary only, not any internal business logic.

```perl
# Concrete mock UA injection pattern for tests:
package MockUA;
sub new { bless {}, shift }
sub post { ... }   # returns a Mojo::Transaction-like object
sub get  { ... }
sub delete { ... }

my $render = Registry::Service::Render->new(
    api_key    => 'test-key',
    service_id => 'svc-test',
    ua         => MockUA->new,
);
```

- [ ] **Step 1: Write the failing test**

Create `t/service/render-api.t` covering:
- `add_custom_domain` — POST to Render API, returns domain ID
- `verify_custom_domain` — POST verify, returns status
- `remove_custom_domain` — DELETE
- `get_custom_domain` — GET status
- Error handling: API failures, invalid responses
- Correct request format (headers, body, URL construction)

- [ ] **Step 2: Run test to verify it fails**

Run: `carton exec prove -lv t/service/render-api.t`
Expected: FAIL

- [ ] **Step 3: Write implementation**

Create `lib/Registry/Service/Render.pm` following the pattern in `lib/Registry/Service/Stripe.pm`:

```perl
# ABOUTME: Client for Render.com Custom Domains API. Handles adding, verifying,
# ABOUTME: and removing custom domains for tenant HTTPS provisioning.
use 5.42.0;
use Object::Pad;

class Registry::Service::Render {
    use Carp qw(croak);
    use Mojo::UserAgent;
    use Mojo::JSON qw(decode_json encode_json);

    field $api_key    :param :reader;
    field $service_id :param :reader;
    field $ua         :param = Mojo::UserAgent->new;
    field $base_url   :param = 'https://api.render.com/v1';

    method _headers {
        return {
            Authorization  => "Bearer $api_key",
            'Content-Type' => 'application/json',
            Accept         => 'application/json',
        };
    }

    method add_custom_domain ($domain) {
        my $url = "$base_url/services/$service_id/custom-domains";
        my $tx  = $ua->post($url => $self->_headers => json => { name => $domain });

        croak "Render API error: " . $tx->res->body
            unless $tx->result->is_success;

        return $tx->result->json;
    }

    method verify_custom_domain ($render_domain_id) {
        my $url = "$base_url/services/$service_id/custom-domains/$render_domain_id/verify";
        my $tx  = $ua->post($url => $self->_headers);

        croak "Render API error: " . $tx->res->body
            unless $tx->result->is_success;

        return $tx->result->json;
    }

    method remove_custom_domain ($render_domain_id) {
        my $url = "$base_url/services/$service_id/custom-domains/$render_domain_id";
        my $tx  = $ua->delete($url => $self->_headers);

        croak "Render API error: " . $tx->res->body
            unless $tx->result->is_success;

        return 1;
    }

    method get_custom_domain ($render_domain_id) {
        my $url = "$base_url/services/$service_id/custom-domains/$render_domain_id";
        my $tx  = $ua->get($url => $self->_headers);

        croak "Render API error: " . $tx->res->body
            unless $tx->result->is_success;

        return $tx->result->json;
    }
}

1;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `carton exec prove -lv t/service/render-api.t`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/Registry/Service/Render.pm t/service/render-api.t
git commit -m "Add Render API client for custom domain management"
```

---

## Task 6: Custom Domain Tenant Resolution

> **Requires: Task 3** (the `tenant_domains` table must be deployed before this runs).

**Files:**
- Modify: `lib/Registry.pm` (tenant helper) — **append to existing file, do not overwrite**
- Modify: `t/integration/custom-domain-resolution.t` (add new subtests)

The custom domain lookup uses `$c->dao('registry')->db` to get the registry-schema database handle — this is consistent with how the rest of `lib/Registry.pm` accesses the registry schema. Do not instantiate `Registry::DAO->new` directly; use the `dao` helper that is already wired to `$ENV{DB_URL}`.

Note: the per-request DB lookup is an accepted trade-off documented in the spec. The index on `tenant_domains.domain` keeps it sub-millisecond. Caching can be added later if profiling identifies it as a bottleneck.

- [ ] **Step 1: Add tests for custom domain resolution**

Add subtests to `t/integration/custom-domain-resolution.t`:

```perl
subtest 'Custom domain resolves to correct tenant' => sub {
    # Insert a verified domain for the dance_stars tenant
    $dao->db->insert('tenant_domains', {
        tenant_id  => $tenant->id,
        domain     => 'dance-stars.com',
        status     => 'verified',
        is_primary => 1,
    });

    $t->get_ok('/auth/login' => { Host => 'dance-stars.com' })
      ->status_is(200, 'Custom domain resolves successfully');
};

subtest 'Unverified custom domain does not resolve' => sub {
    $dao->db->insert('tenant_domains', {
        tenant_id  => $tenant->id,
        domain     => 'pending.dance-stars.com',
        status     => 'pending',
    });

    $t->get_ok('/auth/login' => { Host => 'pending.dance-stars.com' })
      ->status_isnt(200, 'Pending domain does not resolve to tenant');
};
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `carton exec prove -lv t/integration/custom-domain-resolution.t`
Expected: FAIL

- [ ] **Step 3: Add custom domain lookup to tenant helper**

In the `tenant` helper in `lib/Registry.pm`, add a custom domain lookup between the subdomain extraction and the fallback to `'registry'`. Use `$c->dao('registry')->db` to obtain the registry-schema DB handle:

```perl
tenant => sub ($c, $explicit_tenant = undef) {
    my $raw = $explicit_tenant
        || $c->req->headers->header('X-As-Tenant')
        || $c->req->cookie('as-tenant')
        || $self->_extract_tenant_from_subdomain($c);

    # Custom domain lookup: if no tenant found via subdomain/header/cookie,
    # check whether the Host header matches a verified custom domain.
    # Uses $c->dao('registry')->db so the lookup goes through the existing
    # helper (respecting $ENV{DB_URL}) rather than a bare Registry::DAO->new.
    # The per-request query is an accepted trade-off; the domain index makes
    # it sub-millisecond.
    unless ($raw) {
        my $host = lc($c->req->url->to_abs->host // '');
        if ($host && $host !~ /\blocalhost\b/) {
            try {
                require Registry::DAO::TenantDomain;
                my $db = $c->dao('registry')->db;
                my $td = Registry::DAO::TenantDomain->find_by_domain($db, $host);
                if ($td && $td->status eq 'verified') {
                    require Registry::DAO::Tenant;
                    my $tenant = Registry::DAO::Tenant->find($db, { id => $td->tenant_id });
                    $raw = $tenant->slug if $tenant;
                }
            }
            catch ($e) {
                $c->app->log->warn("Custom domain lookup failed: $e");
            }
        }
    }

    $raw //= 'registry';

    # Sanitize: tenant slugs must be safe SQL identifiers
    return 'registry' unless $raw =~ /\A[a-z][a-z0-9_]{0,62}\z/;

    return $raw;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `carton exec prove -lv t/integration/custom-domain-resolution.t`
Expected: PASS

- [ ] **Step 5: Run broader regression tests**

Run: `carton exec prove -lr t/controller/ t/integration/`
Expected: All pass

- [ ] **Step 6: Commit**

```bash
git add lib/Registry.pm t/integration/custom-domain-resolution.t
git commit -m "Add custom domain tenant resolution via tenant_domains table"
```

---

## Task 7a: Admin Domain Controller — index and add

**Files:**
- Create: `lib/Registry/Controller/TenantDomains.pm` (initial, with `index` and `add`)
- Modify: `lib/Registry.pm` (add routes under admin-only group)
- Create: `t/controller/tenant-domains.t` (initial subtests)

Routes must live under a **dedicated admin-only route group**, not the shared admin/staff group. Staff must be rejected from all domain management routes. Concrete method signatures:

```perl
method index ($c)       # GET  /admin/domains
method add ($c)         # POST /admin/domains
method verify ($c)      # POST /admin/domains/:id/verify
method set_primary ($c) # POST /admin/domains/:id/primary
method remove ($c)      # DELETE /admin/domains/:id
```

- [ ] **Step 1: Write the failing test for index and add**

Create `t/controller/tenant-domains.t` with subtests for:
- `GET /admin/domains` as admin — lists domains (200)
- `GET /admin/domains` as staff — rejected (403)
- `GET /admin/domains` unauthenticated — redirected to login
- `POST /admin/domains` with valid domain — creates record, returns 201 or redirect
- `POST /admin/domains` with invalid format — returns 422 with error
- `POST /admin/domains` with tinyartempire.com subdomain — returns 422 with error
- `POST /admin/domains` when tenant already has a domain — returns 422 (1-domain limit enforced in controller)
- `POST /admin/domains` with duplicate (another tenant has it) — returns 422
- Passkey re-registration warning is present in the response when adding a domain to a tenant that has passkey users

```perl
#!/usr/bin/env perl
# ABOUTME: Controller tests for the admin domain management interface.
# ABOUTME: Covers authorization, add/list/verify/set_primary/remove operations.
use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Mojo;
use Test::Registry::DB;
use Test::Registry::Fixtures;

my $tdb = Test::Registry::DB->new;
my $dao = $tdb->db;
$ENV{DB_URL} = $tdb->uri;

my $tenant = Test::Registry::Fixtures::create_tenant($dao, {
    name => 'Admin Domain Tenant',
    slug => 'admin_domain_tenant',
});

my $admin_user = Test::Registry::Fixtures::create_user($dao, {
    tenant_slug => $tenant->slug,
    user_type   => 'admin',
});
my $staff_user = Test::Registry::Fixtures::create_user($dao, {
    tenant_slug => $tenant->slug,
    user_type   => 'staff',
});

my $t = Test::Mojo->new('Registry');

subtest 'Unauthenticated access redirected' => sub {
    $t->get_ok('/admin/domains' => { Host => $tenant->slug . '.localhost' })
      ->status_is(302, 'Unauthenticated user redirected');
};

subtest 'Staff cannot access domain management' => sub {
    Test::Registry::Helpers::login_as($t, $staff_user);
    $t->get_ok('/admin/domains' => { Host => $tenant->slug . '.localhost' })
      ->status_is(403, 'Staff user rejected from domain management');
};

subtest 'Admin can list domains' => sub {
    Test::Registry::Helpers::login_as($t, $admin_user);
    $t->get_ok('/admin/domains' => { Host => $tenant->slug . '.localhost' })
      ->status_is(200, 'Admin can access domain list');
};

subtest 'Admin can add a valid domain' => sub {
    Test::Registry::Helpers::login_as($t, $admin_user);
    $t->post_ok('/admin/domains' => { Host => $tenant->slug . '.localhost' },
        form => { domain => 'new-domain.example.com' })
      ->status_isnt(422, 'Valid domain not rejected');

    my $td = Registry::DAO::TenantDomain->find_by_domain($dao->db, 'new-domain.example.com');
    ok($td, 'Domain row created in database');
    is($td->status, 'pending', 'New domain starts as pending');
};

subtest 'Add domain shows passkey re-registration warning' => sub {
    # The response or redirect target must contain the warning about passkeys
    # when a domain is successfully added.
    Test::Registry::Helpers::login_as($t, $admin_user);
    $t->post_ok('/admin/domains' => { Host => $tenant->slug . '.localhost' },
        form => { domain => 'passkey-warn.example.com' });
    # Follow redirect to index or DNS instructions page
    $t->content_like(qr/passkey|re-register/i,
        'Page contains passkey re-registration warning');
};

subtest 'Add domain rejects invalid format' => sub {
    Test::Registry::Helpers::login_as($t, $admin_user);
    $t->post_ok('/admin/domains' => { Host => $tenant->slug . '.localhost' },
        form => { domain => 'not_a_domain' })
      ->status_is(422, 'Invalid domain format rejected');
};

subtest 'Add domain rejects tinyartempire.com subdomains' => sub {
    Test::Registry::Helpers::login_as($t, $admin_user);
    $t->post_ok('/admin/domains' => { Host => $tenant->slug . '.localhost' },
        form => { domain => 'sub.tinyartempire.com' })
      ->status_is(422, 'tinyartempire.com subdomain rejected');
};

subtest 'Add domain enforces 1-domain limit' => sub {
    # Tenant already has a domain from previous subtest
    Test::Registry::Helpers::login_as($t, $admin_user);
    $t->post_ok('/admin/domains' => { Host => $tenant->slug . '.localhost' },
        form => { domain => 'second-domain.example.com' })
      ->status_is(422, '1-domain limit enforced by controller');
};

done_testing();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `carton exec prove -lv t/controller/tenant-domains.t`
Expected: FAIL

- [ ] **Step 3: Create the controller with index and add**

Create `lib/Registry/Controller/TenantDomains.pm` with `index` and `add` methods.

`index` signature: `method index ($c)` — fetches all domains for the current tenant via `TenantDomain->for_tenant` and renders the list template.

`add` signature: `method add ($c)` — validates domain format via `TenantDomain->validate_domain`, enforces the 1-domain limit (checks `for_tenant` count), calls Render API client to register, inserts row, redirects or renders DNS instructions.

- [ ] **Step 4: Register routes under admin-only group in Registry.pm**

```perl
# Domain management routes (admin-only — staff cannot access)
my $admin_domains = $admin_only->under('/domains');
$admin_domains->get('/')->to('TenantDomains#index')->name('admin_domains');
$admin_domains->post('/')->to('TenantDomains#add')->name('admin_domains_add');
$admin_domains->post('/:id/verify')->to('TenantDomains#verify')->name('admin_domains_verify');
$admin_domains->post('/:id/primary')->to('TenantDomains#set_primary')->name('admin_domains_primary');
$admin_domains->delete('/:id')->to('TenantDomains#remove')->name('admin_domains_remove');
```

- [ ] **Step 5: Run test to verify it passes**

Run: `carton exec prove -lv t/controller/tenant-domains.t`
Expected: PASS for index and add subtests

- [ ] **Step 6: Commit**

```bash
git add lib/Registry/Controller/TenantDomains.pm lib/Registry.pm t/controller/tenant-domains.t
git commit -m "Add TenantDomains controller: index and add with admin-only routes"
```

---

## Task 7b: Admin Domain Controller — verify, set_primary, remove

**Files:**
- Modify: `lib/Registry/Controller/TenantDomains.pm` (add remaining methods)
- Modify: `t/controller/tenant-domains.t` (add subtests)

- [ ] **Step 1: Add tests for verify, set_primary, and remove**

Add subtests to `t/controller/tenant-domains.t`:

```perl
subtest 'Trigger verification check' => sub {
    # Uses existing domain from earlier subtest (or set up fresh domain)
    my $td = Registry::DAO::TenantDomain->find_by_domain($dao->db, 'new-domain.example.com');
    Test::Registry::Helpers::login_as($t, $admin_user);
    $t->post_ok("/admin/domains/@{[$td->id]}/verify"
        => { Host => $tenant->slug . '.localhost' })
      ->status_isnt(500, 'Verify endpoint reachable');
};

subtest 'Set primary domain' => sub {
    my $td = Registry::DAO::TenantDomain->find_by_domain($dao->db, 'new-domain.example.com');
    # Mark verified first so it can become primary
    $td->mark_verified($dao->db);

    Test::Registry::Helpers::login_as($t, $admin_user);
    $t->post_ok("/admin/domains/@{[$td->id]}/primary"
        => { Host => $tenant->slug . '.localhost' })
      ->status_isnt(500, 'Set primary endpoint reachable');

    my $reloaded = Registry::DAO::TenantDomain->find($dao->db, { id => $td->id });
    is($reloaded->is_primary, 1, 'Domain marked as primary');

    my $t_reloaded = Registry::DAO::Tenant->find($dao->db, { id => $tenant->id });
    is($t_reloaded->canonical_domain, 'new-domain.example.com',
        'Tenant canonical_domain updated after set_primary');
};

subtest 'Remove a non-primary domain' => sub {
    my $extra = $dao->db->insert('tenant_domains', {
        tenant_id => $tenant->id,
        domain    => 'to-delete.example.com',
        status    => 'pending',
    }, { returning => '*' })->hash;

    Test::Registry::Helpers::login_as($t, $admin_user);
    $t->delete_ok("/admin/domains/$extra->{id}"
        => { Host => $tenant->slug . '.localhost' })
      ->status_isnt(500, 'Remove endpoint reachable');

    my $gone = Registry::DAO::TenantDomain->find_by_domain($dao->db, 'to-delete.example.com');
    ok(!$gone, 'Domain row removed from database');
};

subtest 'Remove primary domain clears canonical_domain' => sub {
    my $td = Registry::DAO::TenantDomain->find_by_domain($dao->db, 'new-domain.example.com');
    Test::Registry::Helpers::login_as($t, $admin_user);
    $t->delete_ok("/admin/domains/@{[$td->id]}"
        => { Host => $tenant->slug . '.localhost' })
      ->status_isnt(500, 'Remove primary domain endpoint reachable');

    my $t_reloaded = Registry::DAO::Tenant->find($dao->db, { id => $tenant->id });
    is($t_reloaded->canonical_domain, undef,
        'canonical_domain cleared after removing primary domain');
};
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `carton exec prove -lv t/controller/tenant-domains.t`
Expected: new subtests fail

- [ ] **Step 3: Add verify, set_primary, and remove methods to the controller**

`verify` signature: `method verify ($c)` — finds domain by `$c->param('id')`, calls Render API `verify_custom_domain`, delegates to `$td->mark_verified` or `$td->mark_failed`.

`set_primary` signature: `method set_primary ($c)` — finds domain, calls `$td->set_primary($db)`.

`remove` signature: `method remove ($c)` — finds domain, calls Render API `remove_custom_domain`, then `$td->remove($db)`.

- [ ] **Step 4: Run all controller tests to verify they pass**

Run: `carton exec prove -lv t/controller/tenant-domains.t`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/Registry/Controller/TenantDomains.pm t/controller/tenant-domains.t
git commit -m "Add TenantDomains controller: verify, set_primary, and remove"
```

---

## Task 7c: Admin Domain Templates

**Files:**
- Create: `templates/admin/domains/index.html.ep`
- Create: `templates/admin/domains/dns_instructions.html.ep`

- [ ] **Step 1: Create templates per the spec UI section**

`templates/admin/domains/index.html.ep`: Domain list table (domain, status indicator, primary badge, actions), add domain form with the passkey re-registration warning message, and DNS instructions panel (shown inline after adding a domain).

`templates/admin/domains/dns_instructions.html.ep`: CNAME record instructions with note about ALIAS/ANAME for apex domains.

Status indicators from spec:
- **Pending** — yellow, "Waiting for DNS verification"
- **Verified** — green, "Active"
- **Failed** — red, shows `verification_error`, "Check now" to retry

- [ ] **Step 2: Verify the controller tests still pass (templates render without error)**

Run: `carton exec prove -lv t/controller/tenant-domains.t`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add templates/admin/domains/
git commit -m "Add domain management admin templates"
```

---

## Task 8: Email Templates — Domain Verification

**Files:**
- Modify: `lib/Registry/Email/Template.pm`
- Modify or create: `t/dao/email-templates-domains.t`

- [ ] **Step 1: Write the failing test**

Create `t/dao/email-templates-domains.t`:

```perl
#!/usr/bin/env perl
# ABOUTME: Tests for domain verification email templates. Verifies that
# ABOUTME: domain_verified and domain_verification_failed render correctly.
use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Registry::Email::Template;

subtest 'domain_verified template renders' => sub {
    my $html = Registry::Email::Template->render('domain_verified', {
        tenant_name => 'Dance Stars',
        domain      => 'dance-stars.com',
    });
    ok($html, 'domain_verified template produces output');
    like($html, qr/dance-stars\.com/, 'domain name appears in email');
    like($html, qr/Dance Stars/,      'tenant name appears in email');
    like($html, qr/passkey|re-register/i,
        'passkey re-registration note present in domain_verified email');
};

subtest 'domain_verification_failed template renders' => sub {
    my $html = Registry::Email::Template->render('domain_verification_failed', {
        tenant_name => 'Dance Stars',
        domain      => 'dance-stars.com',
        error       => 'CNAME record not found',
        retry_url   => 'https://dance_stars.tinyartempire.com/admin/domains',
    });
    ok($html, 'domain_verification_failed template produces output');
    like($html, qr/dance-stars\.com/,       'domain name appears in email');
    like($html, qr/CNAME record not found/, 'error message appears in email');
    like($html, qr/retry_url|admin\/domains/i, 'retry link present in email');
};

done_testing();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `carton exec prove -lv t/dao/email-templates-domains.t`
Expected: FAIL

- [ ] **Step 3: Add templates to Email::Template**

Add `domain_verified` and `domain_verification_failed` to `lib/Registry/Email/Template.pm`:

- `domain_verified`: variables `tenant_name`, `domain`. Include a note about passkey re-registration (as called out in the spec's WebAuthn Impact section).
- `domain_verification_failed`: variables `tenant_name`, `domain`, `error`, `retry_url`.

- [ ] **Step 4: Run test to verify it passes**

Run: `carton exec prove -lv t/dao/email-templates-domains.t`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/Registry/Email/Template.pm t/dao/email-templates-domains.t
git commit -m "Add domain verification email templates"
```

---

## Task 9: Background Domain Verification Job

**Files:**
- Create: `lib/Registry/Job/DomainVerification.pm`
- Create: `t/job/domain-verification.t`
- Modify: `lib/Registry.pm` (register job and schedule)

- [ ] **Step 1: Write the failing test**

Create `t/job/domain-verification.t` following the structure of `t/job/attendance-check.t`:

```perl
#!/usr/bin/env perl
# ABOUTME: Tests for the DomainVerification Minion job. Verifies that pending
# ABOUTME: domains are checked via Render API and status updates are persisted.
use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;

use Registry::Job::DomainVerification;
use Registry::DAO::TenantDomain;

my $tdb = Test::Registry::DB->new;
my $dao = $tdb->db;
my $db  = $dao->db;

$ENV{DB_URL} = $tdb->uri;

my $tenant = Test::Registry::Fixtures::create_tenant($dao, {
    name => 'Job Test Tenant',
    slug => 'job_test_tenant',
});

# Build a minimal mock Render client that records calls and returns canned responses
{
    package MockRenderClient;
    sub new { bless { calls => [] }, shift }
    sub verify_custom_domain {
        my ($self, $render_id) = @_;
        push @{ $self->{calls} }, $render_id;
        return { verified => 1 };   # simulate success
    }
    sub calls { shift->{calls} }
}

subtest 'Pending domains within 7 days are checked' => sub {
    my $td = Registry::DAO::TenantDomain->create($db, {
        tenant_id        => $tenant->id,
        domain           => 'pending-check.example.com',
        status           => 'pending',
        render_domain_id => 'rdm_abc123',
    });

    my $mock_render = MockRenderClient->new;
    my $job = Registry::Job::DomainVerification->new;
    $job->check_pending_domains($db, $mock_render);

    is(scalar @{ $mock_render->calls }, 1, 'Render verify called once');
    is($mock_render->calls->[0], 'rdm_abc123', 'Correct render_domain_id used');

    my $updated = Registry::DAO::TenantDomain->find($db, { id => $td->id });
    is($updated->status, 'verified', 'Domain status updated to verified');

    $db->delete('tenant_domains', { id => $td->id });
};

subtest 'Domains older than 7 days are skipped' => sub {
    # Insert domain with created_at > 7 days ago
    $db->query(
        "INSERT INTO tenant_domains (tenant_id, domain, status, render_domain_id, created_at)
         VALUES (?, ?, 'pending', 'rdm_old', now() - interval '8 days')",
        $tenant->id, 'old-pending.example.com'
    );

    my $mock_render = MockRenderClient->new;
    my $job = Registry::Job::DomainVerification->new;
    $job->check_pending_domains($db, $mock_render);

    is(scalar @{ $mock_render->calls }, 0, 'Expired domain not checked');

    $db->delete('tenant_domains', { domain => 'old-pending.example.com' });
};

subtest 'Failed verification stores error message' => sub {
    {
        package FailingRenderClient;
        sub new { bless {}, shift }
        sub verify_custom_domain { die "CNAME not found\n" }
    }

    my $td = Registry::DAO::TenantDomain->create($db, {
        tenant_id        => $tenant->id,
        domain           => 'fail-check.example.com',
        status           => 'pending',
        render_domain_id => 'rdm_fail',
    });

    my $failing_render = FailingRenderClient->new;
    my $job = Registry::Job::DomainVerification->new;
    $job->check_pending_domains($db, $failing_render);

    my $updated = Registry::DAO::TenantDomain->find($db, { id => $td->id });
    is($updated->status, 'failed', 'Domain status set to failed on error');
    like($updated->verification_error, qr/CNAME not found/, 'Error message stored');

    $db->delete('tenant_domains', { id => $td->id });
};

subtest 'Job registers with Minion' => sub {
    my $tasks_registered = {};
    my $mock_minion = bless {
        tasks => $tasks_registered,
    }, 'MockMinion';
    {
        package MockMinion;
        sub add_task { my ($self, $name, $cb) = @_; $self->{tasks}{$name} = $cb }
    }
    my $mock_app = bless { minion => $mock_minion }, 'MockApp';
    {
        package MockApp;
        sub minion { shift->{minion} }
    }

    Registry::Job::DomainVerification->register($mock_app);
    ok(exists $tasks_registered->{domain_verification},
        'domain_verification task registered with Minion');
};

$tdb->cleanup_test_database;
done_testing();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `carton exec prove -lv t/job/domain-verification.t`
Expected: FAIL — module does not exist

- [ ] **Step 3: Write the job**

Create `lib/Registry/Job/DomainVerification.pm` following the pattern in `lib/Registry/Job/AttendanceCheck.pm`:

```perl
# ABOUTME: Minion background job that periodically checks pending custom domains
# ABOUTME: via the Render API and updates their verification status.
use 5.42.0;
use Object::Pad;

class Registry::Job::DomainVerification {
    use Registry::DAO;
    use Registry::DAO::TenantDomain;
    use Registry::Service::Render;

    sub register ($class, $app) {
        $app->minion->add_task(domain_verification => sub ($job, @args) {
            $class->new->run($job, @args);
        });
    }

    method run ($job, @args) {
        my $db = $job->app->dao('registry')->db;
        my $render = Registry::Service::Render->new(
            api_key    => $ENV{RENDER_API_KEY},
            service_id => $ENV{RENDER_SERVICE_ID},
        );
        $self->check_pending_domains($db, $render);
    }

    # check_pending_domains is a separate method to allow direct unit testing
    # without a full Minion job context (following AttendanceCheck pattern).
    method check_pending_domains ($db, $render) {
        my @pending = $db->select('tenant_domains', '*',
            \[ "status = 'pending' AND created_at > now() - interval '7 days'" ]
        )->hashes->map(sub { Registry::DAO::TenantDomain->new(%$_) })->each;

        for my $td (@pending) {
            next unless $td->render_domain_id;
            eval {
                $render->verify_custom_domain($td->render_domain_id);
                $td->mark_verified($db);
            };
            if ($@) {
                (my $err = $@) =~ s/\s+$//;
                $td->mark_failed($db, $err);
            }
        }
    }
}

1;
```

- [ ] **Step 4: Register and schedule in Registry.pm**

Add to `setup_recurring_jobs` (or equivalent):

```perl
# Schedule domain verification to run every 15 minutes
$app->minion->enqueue('domain_verification') unless $already_scheduled;
```

Also register the job class in the startup:

```perl
Registry::Job::DomainVerification->register($app);
```

- [ ] **Step 5: Run test to verify it passes**

Run: `carton exec prove -lv t/job/domain-verification.t`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/Registry/Job/DomainVerification.pm t/job/domain-verification.t lib/Registry.pm
git commit -m "Add background domain verification Minion job"
```

---

## Task 10: Final Verification

- [ ] **Step 1: Import workflows**

Run: `carton exec ./registry workflow import registry`

- [ ] **Step 2: Run complete test suite**

Run: `carton exec prove -lr t/`
Expected: ALL tests pass at 100%

- [ ] **Step 3: Fix any remaining failures**

Address any test failures before proceeding. No test may be left failing.

- [ ] **Step 4: Playwright tests — deferred**

End-to-end Playwright tests for the domain management UI are deferred to a follow-up issue. The spec calls for `t/playwright/custom-domains.spec.js` covering: admin navigates to domain page, adds a domain, sees DNS instructions, status indicators render, set-primary confirmation, remove domain. Track this as a GitHub issue referencing this plan.

Create the tracking issue:
```bash
gh issue create \
  --title "Add Playwright e2e tests for custom domain management UI" \
  --body "Follow-up to custom-domains implementation. See docs/superpowers/plans/2026-03-30-custom-domains.md Task 10 Step 4 for scope." \
  --label "type:test,effort:medium"
```

- [ ] **Step 5: Commit**

```bash
git commit -m "Final verification: all tests pass for custom domains"
```
