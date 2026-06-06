# Tenant Isolation Foundation — Design

ABOUTME: Design for making Registry workflows operate in per-tenant schemas.
ABOUTME: Foundation work that unblocks the Morgan -> Nancy -> Amara lifecycle E2E (#224).

- Status: Draft (pending review)
- Date: 2026-06-06
- Related: #224 (lifecycle E2E), #41 (hyphen slugs), #173 (per-tenant DB templates), #154 (pricing_plans in tenant schema)

## 1. Problem

Registry is multi-tenant by Postgres schema: each tenant's data lives in a schema
named for its slug, and `Registry::DAO->new(schema => $slug)` scopes the connection's
`search_path` to `[$slug, public]`. Most controllers honor this via
`$self->dao($self->stash('tenant'))`.

The **Workflows controller does not**. Every data-access site in
`lib/Registry/Controller/Workflows.pm` (8 of them) uses `$self->app->dao`, which
resolves to the registry-default schema regardless of request context. Because nearly
every meaningful action in Registry is a workflow (program creation, location
assignment, registration, the storefront itself), this means **workflow-created data
always lands in the `registry` schema**, never in the acting tenant's schema.

Concretely, this was discovered while building the lifecycle E2E (#224): Morgan, an
admin of tenant `lifecycle_<ts>`, creates a program and it lands in `registry`. His
tenant schema (which the seed never even provisions) stays empty. The tenant storefront,
parent registration, and attendance all then have to operate against `registry` to find
the data — which is incorrect and blocks a faithful multi-tenant journey.

## 2. Goals / Non-goals

**Goals**
- Workflows execute against the acting tenant's schema, app-wide.
- A tenant provisioned through the real signup flow can run the full operator journey
  (program creation, location assignment, storefront, registration) entirely within its
  own schema.
- Tenant context is carried by subdomain (`<slug>.host`), the production mechanism, for
  both authenticated and unauthenticated requests.
- The Playwright harness never receives live Stripe credentials.
- All existing tests remain green (100% pass requirement).

**Non-goals (this sub-project)**
- The lifecycle E2E itself (Nancy registration, Amara attendance, unified spec) —
  that is Sub-project B, which depends on this.
- Full resolution of #41 (human-named tenants with hyphenated subdomains and
  underscore schema-name mapping). We defer it with a hostname-safe seed slug and call
  it out as the production follow-up.
- Per-tenant DB templates (#173) and pricing-plan tenant-schema cleanup (#154) beyond
  what this journey needs.

## 3. Decisions (settled with the requester)

1. **Full app-wide tenant isolation**, not a narrowly scoped patch.
2. **Provision via the real `tenant-signup` workflow**, not by calling provisioning
   primitives directly. This also gives the lifecycle a genuine signup leg.
3. **Tenant context = subdomain via `*.localhost`** in tests, matching production
   subdomain resolution.

## 4. Design

### 4.1 Workflows controller becomes tenant-aware

Replace `$self->app->dao` in `Workflows.pm` with a tenant-resolved dao. The tenant is
already available via the `tenant` helper (`$self->tenant`), which resolves
explicit-param > X-As-Tenant (authed) > subdomain > `registry` default. A single
private accessor keeps the sites consistent:

```perl
method _dao { $self->dao( $self->tenant ) }
```

All eight `app->dao` call sites switch to `$self->_dao`. Because `$self->tenant`
defaults to `registry` when no context is present, **existing registry-context requests
are unaffected**; only requests carrying tenant context route elsewhere.

**Chicken-and-egg exception — `tenant-signup`.** The signup workflow creates the tenant
and its schema in its final `RegisterTenant` step, so its run must execute in `registry`
until that point. `tenant-signup` is therefore pinned to the `registry` schema for the
whole run (the new schema does not exist while the run is in flight; `RegisterTenant`
writes the new schema explicitly via its own tenant-scoped dao, which it already does).
Detection is by workflow slug (`tenant-signup`), kept in one guard in `_dao`.

### 4.2 Workflow definitions and runs live in the tenant schema

`clone_schema($slug)` clones table structure (including `workflows`, `workflow_steps`,
`workflow_runs`). `RegisterTenant` then `copy_workflow`s a fixed list of workflow
definitions into the new schema. That list is missing `program-location-assignment` and
the storefront registration workflow, so they are added:

- Add `program-location-assignment` and `summer-camp-registration` to the
  `RegisterTenant` copy list (the operator and parent both need them in-tenant).

Workflow runs are created and read through the tenant-scoped dao (4.1), so they live in
the tenant schema alongside the data they touch.

### 4.3 Tenant context by subdomain

Production resolves tenant from `<slug>.example.com` via
`_extract_tenant_from_subdomain`, which rejects bare IPs (hence `127.0.0.1` falls back to
`registry` today). In tests we drive the browser at `http://<slug>.localhost:3001/`;
Chromium resolves `*.localhost` to loopback, and the server extracts `<slug>` from the
Host header. The `localhost` host short-circuits the custom-domain DB lookup, which is
correct.

**Slug constraint.** Tenant slugs permit `[a-z][a-z0-9_]*` (underscores, not hyphens —
#41). Underscores are not valid DNS hostname characters and Chromium may reject them.
The signup flow generates a subdomain slug from the org name; to stay hostname-safe
without taking on #41, the lifecycle seed uses an **all-alphanumeric org name** that
yields a slug like `lifecycleNNN` (lowercase letters + digits only). #41 remains the
real fix for human-named tenants (hyphenated subdomain -> underscore schema-name
mapping) and is referenced, not solved, here.

### 4.4 Harness Stripe safety

`TenantPayment` already has a test-mode branch: when no Stripe keys are configured it
creates a mock subscription and advances to `complete` (`RegisterTenant`). The harness
currently inherits the developer's shell environment, which may include a **live**
`STRIPE_SECRET_KEY`. `t/playwright/global-setup.js` will explicitly clear
`STRIPE_SECRET_KEY` and `STRIPE_PUBLISHABLE_KEY` from the server's environment so signup
takes the mock path and no live key ever reaches the harness. (This pre-existing
test-mode branch is used as-is; no new mock code is introduced.)

### 4.5 Existing-test fallout

Once `app->dao` no longer forces `registry`, any workflow-driving test that implicitly
relied on registry-context data must be checked. Affected suites likely include the
Playwright specs that drive workflows (`tenant-signup`, `jordan-*`, `amara-attendance`,
`waitlist-flow`, `camp-registration`, `parent-dashboard`, `admin-dashboard`) and any DAO
tests exercising the Workflows controller. The expectation is that most are unaffected
(they run without tenant context, so still resolve to `registry`), but each is run and
any genuine fallout fixed. This is the highest-uncertainty part of the work and is
treated as its own verification pass.

## 5. Testing strategy

- TDD at the integration layer using the existing Playwright harness (one Test::PostgreSQL
  DB + one daemon), which already imports workflows/templates from disk per run.
- New/extended coverage:
  - A focused test that a tenant provisioned via `tenant-signup` has
    `program-location-assignment` and `summer-camp-registration` in its schema.
  - Morgan's existing program-setup spec re-pointed at his tenant subdomain, asserting
    the project/session/events land in the **tenant** schema (not registry).
  - global-setup asserted to start the server without Stripe keys.
- Full `t/dao/` and the Playwright suite run as the regression gate. Pre-existing failure
  #227 (`program-listing-filters.t`) is tracked separately and not introduced here.

## 6. Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| App-wide `_dao` change breaks existing workflow specs | Run every workflow spec; fix genuine fallout in a dedicated pass; registry default limits blast radius. |
| `tenant-signup` run misrouted to a not-yet-existent schema | Pin `tenant-signup` to registry by slug in `_dao`; `RegisterTenant` keeps writing the new schema via its own dao. |
| Chromium rejects underscore/non-DNS slug hostnames | Seed uses all-alphanumeric slug; #41 deferred and referenced. |
| Live Stripe key reaches harness | global-setup clears Stripe env vars; verified by test. |
| `copy_workflow` list drift (missing workflows in tenant) | Add the two needed workflows; a provisioning test guards the set. |

## 7. Sequencing

1. global-setup Stripe-key clearing (independent, low risk, also a safety fix).
2. Add `program-location-assignment` + `summer-camp-registration` to `RegisterTenant`
   copy list; provisioning test.
3. `Workflows.pm` `_dao` change + `tenant-signup` registry pin.
4. Run full regression; fix fallout (the big unknown).
5. Hand off to Sub-project B (lifecycle E2E in-tenant).

## 8. Open questions

- Should `tenant-signup` be the only registry-pinned workflow, or are there others that
  legitimately operate cross-tenant (e.g. platform admin)? Current evidence says only
  `tenant-signup`; to be confirmed during the fallout pass.
- Is `summer-camp-registration` the correct registration workflow for Morgan's program,
  or should the program's `registration_workflow` metadata point elsewhere? Resolved in
  Sub-project B when wiring Nancy's registration.
