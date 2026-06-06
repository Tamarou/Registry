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

**Assumptions**
- Registry is **pre-alpha with no production tenant data** (per CLAUDE.md). This is what
  makes the app-wide `app->dao -> _dao` switch safe: there is no tenant whose data is
  currently stranded in the `registry` schema and would be orphaned when its requests
  begin routing to its own schema. If that ceases to be true before this ships, a data
  migration (move per-tenant rows out of `registry` into their tenant schemas) becomes a
  prerequisite and must be specced separately. No backwards-compatibility burden is
  assumed otherwise.

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
`workflow_runs`). `RegisterTenant` then `copy_workflow`s a **hardcoded list** of workflow
definitions into the new schema. That list has already drifted — it silently lacks
`program-location-assignment` — and adding the two workflows this journey needs
(`program-location-assignment`, `summer-camp-registration`) to the same hardcoded list
just defers the next drift.

**Fix the root cause:** copy *every* workflow that exists in the `registry` schema into
the new tenant schema, derived from the `workflows` table rather than a literal list, so
the set cannot drift again. (`tenant-signup` is the one workflow that should *not* be
copied — a tenant never re-runs tenant onboarding inside its own schema; it is excluded
explicitly.) This subsumes the original "add two workflows" fix.

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

**Validation spike (first task, gating).** The subdomain mechanism is plausible but
unproven in this harness: Chromium must resolve `<slug>.localhost:3001` to loopback,
send the slug in the Host header, and accept the slug as a valid hostname. Before any
other work, a throwaway spike proves the full path end-to-end — navigate
`http://<slug>.localhost:3001/` and assert the server resolved tenant `<slug>` (e.g. a
debug route echoing `$c->tenant`). If the spike fails, fall back to the **hybrid**
mechanism: `X-As-Tenant` header for authenticated requests (Morgan's operator journey)
and subdomain only for the unauthenticated storefront. The design proceeds on subdomain;
the hybrid is the defined contingency, not a redesign.

### 4.4 Tenant signup completion by price, not env

`TenantPayment` currently auto-completes the signup by detecting the *absence* of Stripe
keys ("test mode") and minting a mock subscription. That is the exact pattern the
codebase has been deliberately removing: #219/#222 moved registration payment off
env-detection and onto **price** ("drive payment-or-not by pricing, not env"). Relying on
env-absence for tenant signup would swim against that current and couple our test to a
deprecated path.

**Apply the #222 treatment to `TenantPayment`:** when the selected tenant plan's
recurring amount is **$0** (the Solo / free-to-start tier), the step completes the signup
without invoking Stripe at all — by price, regardless of whether keys are present. The
lifecycle seed selects the free Solo plan at the pricing step, so signup completes
deterministically and provisions the schema. This removes the env dependency, mirrors the
established registration-payment pattern, and is real product behavior (a $0 plan should
never hit a card).

**Stripe key safety (still required, now defense-in-depth).** Independent of the above,
`t/playwright/global-setup.js` clears `STRIPE_SECRET_KEY` / `STRIPE_PUBLISHABLE_KEY` from
the server environment so a developer's **live** key can never reach the harness. With
the price-based completion this is a safety belt rather than the mechanism the test
depends on. No new mock code is introduced; the existing env-keyed mock branch can be
retired or left dormant as the maintainer prefers.

### 4.5 Existing-test fallout

Once `app->dao` no longer forces `registry`, any workflow-driving test that implicitly
relied on registry-context data must be checked. This is the highest-uncertainty part of
the work, so it is bounded explicitly rather than left open.

**Target set (run all; each must stay green or be fixed):**

- Playwright workflow specs: `tenant-signup`, `jordan-landing-journey`,
  `jordan-admin-dashboard`, `amara-attendance`, `waitlist-flow`, `camp-registration`,
  `parent-dashboard`, `admin-dashboard`, `morgan-program-setup`, `all-workflows-visual`,
  `workflow-layout-visual`, `component-integration`.
- DAO/controller tests that drive workflows: everything under `t/dao/` and
  `t/controller/` (run as suites).

**Expected outcome and done-criteria.** The hypothesis is that nearly all are unaffected:
they issue requests without tenant context, so `$self->tenant` still resolves to
`registry` and behavior is unchanged. Done means: the full Playwright suite and
`t/dao/` + `t/controller/` are green, **except** the pre-existing, separately-tracked
failure #227 (`program-listing-filters.t`), which this work neither fixes nor worsens.
Any spec that genuinely depends on the old `app->dao` behavior is converted into a named
sub-task (explicitly route it to the tenant it means, or assert registry default), not a
silent edit. If the count of genuinely-affected specs exceeds ~3, stop and re-scope with
the maintainer before grinding through them.

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
| App-wide `_dao` change breaks existing workflow specs | Bounded target set (§4.5) with explicit done-criteria; registry default limits blast radius; re-scope trigger if >~3 specs genuinely affected. |
| `tenant-signup` run misrouted to a not-yet-existent schema | Pin `tenant-signup` to registry by slug in `_dao`; `RegisterTenant` keeps writing the new schema via its own dao. |
| Subdomain context unproven in harness (Chromium / `*.localhost` / slug) | Gating validation spike before any other work (§4.3); hybrid `X-As-Tenant`+subdomain fallback defined. |
| Live Stripe key reaches harness | Signup completes by price ($0 plan), not env; global-setup also clears Stripe env vars as defense-in-depth (§4.4). |
| Hardcoded `copy_workflow` list drifts again | Copy all registry workflows (excluding `tenant-signup`) from the `workflows` table; a provisioning test guards the set (§4.2). |
| Existing tenant data stranded in `registry` orphaned by the switch | Pre-alpha assumption stated (§2); if it stops holding, a data migration becomes a prerequisite. |

## 7. Sequencing

0. **Subdomain validation spike** (§4.3) — gating. Prove `<slug>.localhost:3001`
   resolves and the server reads the tenant, or switch to the hybrid fallback. Nothing
   else starts until the context mechanism is settled.
1. global-setup Stripe-key clearing (independent, low risk, safety fix).
2. `RegisterTenant` copies all registry workflows (excluding `tenant-signup`) from the
   `workflows` table; provisioning test asserts the needed workflows land in-tenant.
3. `TenantPayment` completes a $0 plan by price (§4.4); test the free-plan signup path.
4. `Workflows.pm` `_dao` change + `tenant-signup` registry pin.
5. Run the bounded regression target set (§4.5); fix genuine fallout or re-scope.
6. Hand off to Sub-project B (lifecycle E2E in-tenant).

## 8. Open questions

- Should `tenant-signup` be the only registry-pinned workflow, or are there others that
  legitimately operate cross-tenant (e.g. platform admin)? Current evidence says only
  `tenant-signup`; to be confirmed during the fallout pass (§4.5).
- Copying *all* registry workflows into each tenant (§4.2) is the anti-drift fix, but it
  also copies workflows a given tenant may never use. Acceptable (definitions are cheap,
  cloned structure already exists); revisit only if the copy becomes a provisioning-time
  cost.
- Does retiring `TenantPayment`'s env-keyed mock branch (§4.4) affect any existing
  tenant-signup test that depended on it? Checked as part of the §4.5 target set.
