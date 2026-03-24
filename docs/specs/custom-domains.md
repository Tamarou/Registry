# Custom Domain Specification

## Overview

Tenants can bring their own domains (e.g., `dance-stars.com`) to serve their
Registry instance instead of the default `<slug>.tinyartempire.com` subdomain.
Domain management is fully self-service from the tenant admin dashboard.
Certificate provisioning and HTTPS termination are handled by Render.com via
its Custom Domains API.

## Architecture

### Request Flow

```
Browser → dance-stars.com (CNAME) → Render edge (TLS termination)
  → registry-app (Host: dance-stars.com)
  → tenant resolution: subdomain check fails → tenant_domains lookup → found tenant
  → serve response
```

### Tenant Resolution Priority Chain

The existing `tenant` helper in `lib/Registry.pm` resolves tenants in order:

1. Explicit param passed to helper
2. `X-As-Tenant` request header
3. `as-tenant` cookie
4. Subdomain extraction (`_extract_tenant_from_subdomain`)
5. **Custom domain lookup** ← NEW (query `tenant_domains` by `Host` header)
6. Fallback to `registry`

Custom domain lookup is a database query on every request where steps 1–4
return nothing. An index on `tenant_domains.domain` keeps this sub-millisecond.
Optimize with caching later if needed.

### Canonical Domain

Each tenant has a **canonical domain** — the authoritative domain used for:

- WebAuthn relying party ID (from auth spec)
- Magic link URLs
- Email link generation
- `<link rel="canonical">` tags
- Any absolute URL the system generates

The canonical domain is determined by:

1. The primary custom domain (if one exists and is verified)
2. Otherwise, `<slug>.tinyartempire.com`

All non-canonical domains (including the original subdomain after a custom
domain becomes primary) **301-redirect** to the canonical domain. This ensures
a single authoritative origin for WebAuthn credentials, SEO, and user
expectations.

### Redirect Behavior

When a request arrives on a non-canonical domain for a tenant that has a
canonical custom domain:

- **301 Moved Permanently** to the same path on the canonical domain
- Preserves path, query string, and fragment
- Example: `dance-stars.tinyartempire.com/workflow/enrollment?id=5`
  → `301` to `dance-stars.com/workflow/enrollment?id=5`

This redirect happens in the `before_dispatch` hook, after tenant resolution
and before route dispatch.

### WebAuthn Impact

When a tenant sets a new canonical domain, existing passkeys registered under
the old domain become invalid (WebAuthn RP ID changes). Users authenticate via
magic link fallback on the new domain and re-register passkeys. See the auth
system spec (`docs/specs/auth-system.md`) for details.

## Data Model

### `tenant_domains` Table

```sql
CREATE TABLE IF NOT EXISTS tenant_domains (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    domain text NOT NULL UNIQUE,
    status text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'verified', 'failed')),
    is_primary boolean NOT NULL DEFAULT false,
    render_domain_id text,  -- Render API's ID for this custom domain
    verification_error text,  -- last error message from verification attempt
    verified_at timestamptz,
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now()
);

CREATE INDEX idx_tenant_domains_domain ON tenant_domains(domain);
CREATE INDEX idx_tenant_domains_tenant_id ON tenant_domains(tenant_id);

-- Ensure at most one primary domain per tenant
CREATE UNIQUE INDEX idx_tenant_domains_primary
    ON tenant_domains(tenant_id) WHERE is_primary = true;
```

This table lives in the **`registry` schema** (not per-tenant), because domain
resolution must happen before we know which tenant schema to use.

### `tenants` Table Addition

```sql
ALTER TABLE tenants ADD COLUMN IF NOT EXISTS canonical_domain text;
```

Computed/cached field: the verified primary custom domain, or
`<slug>.tinyartempire.com` if none. Updated when domains are verified,
set as primary, or removed. Used by the auth system for WebAuthn RP ID and
magic link URL generation.

## Render API Integration

### Configuration

Environment variables (12-factor, already supported by `render.yaml` env
groups):

- `RENDER_API_KEY` — Render API token with custom domain management
  permissions
- `RENDER_SERVICE_ID` — the `registry-app` service ID

### API Operations

All calls go to `https://api.render.com/v1/services/{serviceId}/custom-domains/`.

#### Add Domain

When a tenant admin enters a new domain:

1. Validate domain format (basic syntax check, no IP addresses, no
   `tinyartempire.com` subdomains)
2. Check uniqueness in `tenant_domains` table
3. `POST /custom-domains` with `{ "name": "dance-stars.com" }`
4. Store the returned `id` as `render_domain_id`
5. Insert row into `tenant_domains` with status `pending`
6. Return the required DNS records to the tenant admin

#### Verify Domain

When the tenant clicks "Check now" or on periodic background check:

1. `POST /custom-domains/{id}/verify`
2. Parse response for verification status
3. Update `tenant_domains.status` to `verified` or `failed`
4. If `verified`: set `verified_at`, send confirmation email to tenant admin
5. If `failed`: store error in `verification_error` for display

#### Remove Domain

When the tenant admin removes a domain:

1. `DELETE /custom-domains/{id}`
2. Delete row from `tenant_domains`
3. If the removed domain was primary, clear `tenants.canonical_domain`
   (reverts to `<slug>.tinyartempire.com`)

### DNS Records

When a domain is added, the tenant admin needs to create:

- **CNAME**: `dance-stars.com` → `registry-app.onrender.com` (or whatever
  Render's service hostname is)

For apex/root domains where CNAME is not allowed, some DNS providers support
ALIAS or ANAME records. The UI should note this.

Render handles `_acme-challenge` and certificate provisioning automatically
once the CNAME is in place.

## New Code

### DAO Class

```perl
class Registry::DAO::TenantDomain :isa(Registry::DAO::Base) {
    field $tenant_id :param :reader;
    field $domain :param :reader;
    field $status :param :reader = 'pending';
    field $is_primary :param :reader = 0;
    field $render_domain_id :param :reader = undef;
    field $verification_error :param :reader = undef;
    field $verified_at :param :reader = undef;

    # Class methods
    # find_by_domain($db, $domain) — used in tenant resolution
    # for_tenant($db, $tenant_id) — list all domains for a tenant

    # Instance methods
    # verify($db, $render_client) — call Render API, update status
    # set_primary($db) — mark as primary, unset other primaries for tenant
    # remove($db, $render_client) — call Render API, delete record
}
```

### Render API Client

```perl
class Registry::Service::Render {
    field $api_key :param :reader;
    field $service_id :param :reader;

    # add_custom_domain($domain) — POST, returns render domain ID
    # verify_custom_domain($render_domain_id) — POST verify
    # remove_custom_domain($render_domain_id) — DELETE
    # get_custom_domain($render_domain_id) — GET status
}
```

Uses `Mojo::UserAgent` for HTTP calls to Render's API. Synchronous (blocking)
calls are fine for admin dashboard actions.

### Controller

Add domain management to the existing admin controller or create
`Registry::Controller::TenantDomains`:

```
GET  /admin/domains           → List tenant's custom domains with status
POST /admin/domains           → Add a new custom domain
POST /admin/domains/:id/verify → Trigger verification check
POST /admin/domains/:id/primary → Set as primary domain
DELETE /admin/domains/:id     → Remove a custom domain
```

All routes require `admin` role via `require_role`.

### Changes to `lib/Registry.pm`

**Tenant resolution** (add between step 4 and 5):

```perl
# After _extract_tenant_from_subdomain returns undef or 'registry':
# Check tenant_domains table for a custom domain match
my $host = $c->req->url->to_abs->host;
my $tenant_domain = Registry::DAO::TenantDomain->find_by_domain($db, $host);
if ($tenant_domain && $tenant_domain->status eq 'verified') {
    $tenant_slug = $tenant_domain->tenant_slug;
}
```

**Canonical domain redirect** (new `before_dispatch` hook, after tenant
resolution):

```perl
# If tenant has a canonical domain and current host doesn't match, redirect
my $canonical = $tenant->canonical_domain;
if ($canonical && $c->req->url->to_abs->host ne $canonical) {
    my $redirect_url = $c->req->url->to_abs->clone;
    $redirect_url->host($canonical);
    $c->res->headers->location($redirect_url->to_string);
    return $c->rendered(301);
}
```

### Email Templates

Add to `Registry::Email::Template`:

- `domain_verified` — "Your custom domain is active"
  - Domain name, tenant name, note about passkey re-registration if applicable
- `domain_verification_failed` — "Domain verification failed"
  - Domain name, error message, link to retry, DNS instructions reminder

### Background Verification (Optional)

A Minion job that periodically re-checks `pending` domains:

- Runs every 15 minutes (or configurable)
- Queries `tenant_domains WHERE status = 'pending' AND created_at > now() - interval '7 days'`
- Calls Render verify API for each
- Updates status, sends email on verification
- Stops checking after 7 days — if still pending, tenant needs to retry
  manually

This is optional for initial implementation. The "Check now" button provides
immediate feedback; the background job just catches cases where DNS propagated
after the tenant stopped watching.

## Self-Service UI

### Domain Management Page (`/admin/domains`)

**Domain list:**

| Domain | Status | Primary | Actions |
|--------|--------|---------|---------|
| dance-stars.com | Verified | Yes | Remove |
| www.dance-stars.com | Pending | No | Check now, Remove |

**Add domain form:**
- Text input for domain name
- "Add Domain" button
- On success: show DNS instructions panel

**DNS instructions panel** (shown after adding a domain):

```
To connect dance-stars.com, create the following DNS record
with your domain registrar:

  Type:  CNAME
  Name:  dance-stars.com (or @ for root domain)
  Value: registry-app.onrender.com

Note: Root/apex domains (e.g., dance-stars.com without a subdomain)
may require an ALIAS or ANAME record instead of CNAME, depending on
your DNS provider.

After creating the record, click "Check now" to verify. DNS changes
can take up to 48 hours to propagate, but typically complete within
minutes.
```

**Status indicators:**
- **Pending** — yellow, "Waiting for DNS verification"
- **Verified** — green, "Active"
- **Failed** — red, shows `verification_error`, "Check now" to retry

**Set as primary** button (only on verified domains):
- Confirmation dialog: "Setting dance-stars.com as your primary domain will
  redirect all traffic from dance-stars.tinyartempire.com. Users with existing
  passkeys will need to re-register them. Continue?"

## Error Handling

| Scenario | Behavior |
|----------|----------|
| Domain already registered to another tenant | "This domain is already in use." |
| Domain is a `tinyartempire.com` subdomain | "Subdomains of tinyartempire.com are managed automatically." |
| Invalid domain format | "Please enter a valid domain name." |
| Render API error on add | "Unable to register domain. Please try again." + log error |
| Render API error on verify | "Verification check failed. Please try again." + log error |
| DNS not propagated yet | "DNS records not found yet. This can take up to 48 hours." |
| Render API rate limit | Back off and retry; don't expose to user |
| Tenant has no verified domains, removes primary | Canonical reverts to `<slug>.tinyartempire.com` |
| Domain verification succeeds but Render cert provisioning delayed | Show "Verified — certificate provisioning in progress" |

## Security Considerations

- **Domain takeover prevention**: Only verified domains serve tenant content.
  Unverified domains in `pending` state are not used for tenant resolution.
- **Domain squatting**: A tenant could register a domain they don't own. Render's
  verification (CNAME must point to Render) prevents serving content on
  unverified domains. The `pending` → `verified` transition requires actual DNS
  control.
- **Render API key security**: Never exposed to the browser. All Render API
  calls are server-side. Key stored as env var, not in code or database.
- **Admin-only access**: All domain management routes require `admin` role.
- **Input validation**: Reject domains that look like IPs, localhost, or
  internal hostnames. Validate against a basic domain regex.
- **Redirect loops**: The canonical domain redirect must skip if the current
  host IS the canonical domain. Guard against misconfiguration where two
  domains point to each other.

## Testing Plan

### Unit Tests (`t/dao/`)

- `t/dao/tenant-domain.t`:
  - CRUD operations on `tenant_domains`
  - `find_by_domain` lookup
  - `is_primary` uniqueness constraint (only one per tenant)
  - Setting and unsetting primary
  - Cascade delete when tenant is deleted
  - Domain format validation

### Controller Tests (`t/controller/`)

- `t/controller/tenant-domains.t`:
  - Add domain (valid, invalid, duplicate, tinyartempire.com subdomain)
  - Verify domain (mock Render API responses)
  - Set primary
  - Remove domain (primary and non-primary)
  - Authorization (admin-only, reject staff/parent)

### Integration Tests (`t/integration/`)

- `t/integration/custom-domain-resolution.t`:
  - Request with custom domain Host header resolves to correct tenant
  - Unverified domain does NOT resolve
  - Non-canonical domain 301-redirects to canonical
  - Redirect preserves path and query string
  - Tenant with no custom domains resolves via subdomain as before
  - Canonical domain updates when primary domain changes

### Service Tests

- `t/service/render-api.t`:
  - `Registry::Service::Render` methods with mocked HTTP responses
  - Error handling for API failures, rate limits, timeouts
  - Correct request format (headers, body, URL construction)

Note: these tests mock the Render API HTTP responses (using `Mojo::UserAgent`
mock transport), NOT the domain lookup or business logic. The "no mocks" rule
applies to internal application behavior; external API boundaries are the
correct place for test doubles.

### Playwright Tests (`t/playwright/`)

- `t/playwright/custom-domains.spec.js`:
  - Admin navigates to domain management page
  - Adds a domain, sees DNS instructions
  - Status indicators render correctly
  - Set-primary confirmation dialog works
  - Remove domain works

## Implementation Order

1. **Database migration** — `tenant_domains` table in `registry` schema,
   `canonical_domain` column on `tenants`
2. **DAO class** — `Registry::DAO::TenantDomain` with full test coverage
3. **Render API client** — `Registry::Service::Render` with service tests
4. **Tenant resolution** — add custom domain lookup step to `lib/Registry.pm`,
   integration tests
5. **Canonical domain redirect** — `before_dispatch` hook, integration tests
6. **Admin controller + UI** — domain management page, controller tests
7. **Email templates** — `domain_verified`, `domain_verification_failed`
8. **Background verification job** — Minion job for periodic pending domain
   checks (optional, can defer)

## Dependencies

No new CPAN dependencies required. Uses:

- `Mojo::UserAgent` (already available) — for Render API calls
- `Mojo::JSON` (already available) — for API request/response encoding
- Existing email infrastructure — for verification notifications

## Open Questions

1. **Apex domain support**: Should the DNS instructions specifically call out
   ALIAS/ANAME/flattened CNAME for apex domains, or just mention it as a note?
   Different registrars handle this differently.
2. **Domain limit per tenant**: Should there be a maximum number of custom
   domains per tenant? Unlimited for now, or cap at e.g., 10?
3. **Domain transfer between tenants**: If a domain is registered to one tenant
   and another tenant tries to add it, should there be a transfer flow, or
   just "already in use"?
