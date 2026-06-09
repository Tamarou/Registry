# Apex-Domain Tenant Resolution — Design (prod hotfix)

ABOUTME: Fix for production 500s where the platform apex domain mis-resolves as a tenant.
ABOUTME: Base-domain-aware subdomain extraction + defensive schema-existence fallback.

- Status: Approved (compressed ceremony — live prod incident)
- Date: 2026-06-08
- Severity: production outage (tinyartempire.com → HTTP 500 on workflow routes)
- Regression exposed by: #231 (controllers switched to `$self->dao`); latent bug in
  `_extract_tenant_from_subdomain`. Related: #41 / #230 (domain/tenant resolution).

## Problem

`tinyartempire.com/` and `/tenant-signup` return HTTP 500 (`relation "workflows" does not
exist`); `/health` is 200. Root cause: the tenant resolver's `_extract_tenant_from_subdomain`
takes the first DNS label of ANY host, so the apex `tinyartempire.com` resolves to a tenant
slug `tinyartempire`. `$self->dao` then connects with `schema => tinyartempire` (a schema
that does not exist), and workflow-driven routes fail on `SELECT * FROM workflows`. Because
subdomain extraction runs before the custom-domain lookup and sets `$raw`, the custom-domain
fallback is skipped. Before #231 (`$self->app->dao`, always `registry`) the mis-resolution
was harmless; #231 made it fatal.

Production serves BOTH wildcard tenant subdomains (`<slug>.tinyartempire.com`) AND verified
custom domains, so subdomain extraction must keep working for real hosts — which requires
knowing the platform base domain(s) to tell a subdomain from the apex.

## Fix

### 1. Configurable base domains (with a production-correct default)
Base domains default to `tinyartempire.com,localhost` in code, so **production is fixed by
merging alone** — no env var to set or forget. `REGISTRY_BASE_DOMAINS` (comma-separated)
overrides the default for other environments (e.g. staging, additional apexes). Lowercased;
empty entries ignored. `localhost` stays in the default so the `<slug>.localhost` test
convention keeps working.

### 2. Base-domain-aware `_extract_tenant_from_subdomain`
Replace "first label of anything" with base-relative extraction:
- lowercase host, strip port; return undef for IPs.
- For each configured base `B`: if `host eq B` → undef (apex, no subdomain); if
  `host =~ /\A([^.]+)\.\Q$B\E\z/` → return that single label, unless it is `www`.
- Host under no known base (a custom domain, or unknown) → undef.

Resulting behavior (base set `{tinyartempire.com, localhost}`):
| Host | Result |
| --- | --- |
| `tinyartempire.com` | undef → custom-domain lookup → `registry` (FIXES PROD) |
| `acme.tinyartempire.com` | `acme` |
| `www.tinyartempire.com` | undef → `registry` |
| `localhost` | undef → `registry` |
| `spike1.localhost` | `spike1` (test convention preserved) |
| `someones-custom-domain.com` | undef → TenantDomain table → its tenant |
| `127.0.0.1` | undef → `registry` |

Resolution ORDER is otherwise unchanged: explicit param → X-As-Tenant (authed) →
subdomain (now base-aware) → custom-domain table → `registry` default.

### 3. Defensive schema-existence fallback
In the `tenant` helper, when the resolved slug is non-`registry`, verify its Postgres schema
exists; if not, log a warning and return `registry`. This degrades gracefully (serve the
platform site) instead of a hard 500 if resolution ever misfires again. One catalog lookup
(`information_schema.schemata`) on the non-registry path, consistent with the already-accepted
per-request custom-domain query. Positive results may be cached in-process to bound cost
(only cache "exists"; never cache "missing", so a newly-provisioned schema is picked up).

### 4. Deploy
Merge and redeploy — that's it. `tinyartempire.com` is the built-in default, so no env var
is required to restore production. Only set `REGISTRY_BASE_DOMAINS` if additional base
domains (e.g. a staging apex) need to serve wildcard subdomains.

## Testing

- Unit test the resolver (`tenant` helper / `_extract_tenant_from_subdomain`) across every
  host class in the table above, with a multi-base configuration, asserting apex → registry
  and `<slug>.base` → slug.
- Test the defensive fallback: a host resolving to a non-existent schema → `registry`, no
  exception.
- Integration: `GET /` with `Host: tinyartempire.com` (base configured) renders 200, not 500
  — the exact regression. (Use Test::Mojo with the base-domain env set.)

## Risks

| Risk | Mitigation |
| --- | --- |
| Base list misconfigured in prod (omits a live base) → those subdomains resolve to registry | PR documents the required env; deploy step explicit; default keeps tests safe |
| Schema-existence check adds per-request cost | Cheap catalog query on non-registry path only; cache positives |
| A real custom domain equal to `X.<base>` | Custom domains are not provisioned under the platform base; out of scope |
