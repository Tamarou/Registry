# Tenant Isolation Foundation — Design

ABOUTME: Design for making Registry workflows operate in per-tenant schemas.
ABOUTME: Foundation work that unblocks the Morgan -> Nancy -> Amara lifecycle E2E (#224).

- Status: Draft (pending review)
- Date: 2026-06-06
- Related: #224 (lifecycle E2E), #41 (hyphen slugs), #173 (per-tenant DB templates),
  #154 (pricing_plans in tenant schema), #23/#76 (PriceOps — platform billing)

## 1. Problem

Registry is multi-tenant by Postgres schema: each tenant's data lives in a schema named
for its slug, and `Registry::DAO->new(schema => $slug)` scopes the connection's
`search_path` to `[$slug, public]`. Controllers are meant to honor this via
`$self->dao($self->stash('tenant'))`.

The **Workflows controller does not.** Every data-access site in
`lib/Registry/Controller/Workflows.pm` (13 of them) uses `$self->app->dao`, which
resolves to the registry-default schema **regardless of request context**. Because nearly
every meaningful action in Registry is a workflow, workflow-created data always lands in
`registry`, never in the acting tenant's schema.

This was proven, not assumed. A controller built with an authenticated request carrying
`X-As-Tenant: <tenant>` resolves as follows:

```
$c->tenant                          -> <tenant>     (request tenant)
$c->dao->current_tenant   (context) -> <tenant>     (tenant schema)   CORRECT
$c->app->dao->current_tenant (app)  -> registry     (drops context)   WRONG
```

So `$self->tenant` already does the right thing; `$self->app->dao` throws the request
context away. The root cause is having **two ways to get a DAO** — one context-aware
(`$self->dao`) and one context-dropping (`$self->app->dao`) that silently falls back to
`registry`. Simply swapping the Workflows call sites would fix today's symptom while
leaving the footgun loaded for the next caller.

## 2. Goals / Non-goals

**Goals**
- A single DAO accessor that is context-aware and cannot silently resolve to `registry`.
- Workflows execute against the acting tenant's schema, app-wide.
- A provisioned tenant can run the full operator journey (program creation, location
  assignment, storefront, registration) entirely within its own schema.
- Tenant context is carried by subdomain (`<slug>.host`), the production mechanism, for
  both authenticated and unauthenticated requests.
- All existing tests remain green (100% pass requirement), modulo the pre-existing,
  separately-tracked failure #227.

**Non-goals (this sub-project)**
- The lifecycle E2E itself (Nancy registration, Amara attendance, unified spec) — that is
  Sub-project B, which depends on this.
- **Platform subscription billing / `TenantPayment` / PriceOps (#23, #76).** The platform
  is itself a tenant and a platform subscription is just a program priced through the same
  PriceOps engine; `TenantPayment`'s bespoke `create_tenant_directly` + env-mock path is
  the anomaly PriceOps unification will dissolve. This foundation does not touch it and
  does not drive the payment-bearing signup workflow.
- Full resolution of #41 (human-named tenants: hyphenated subdomains <-> underscore
  schema-name mapping). Deferred with a hostname-safe seed slug.
- Per-tenant DB templates (#173) and pricing_plans tenant-schema cleanup (#154) beyond
  what this journey needs.

**Assumptions**
- Registry is **pre-alpha with no production tenant data** (per CLAUDE.md). This is what
  makes the app-wide schema-routing change safe: no tenant's data is currently stranded in
  `registry` to be orphaned when its requests begin routing to its own schema. If that
  stops holding before this ships, a data migration becomes a prerequisite and is specced
  separately.

## 3. Decisions (settled with the requester)

1. **Full app-wide tenant isolation**, not a narrowly scoped patch.
2. **Collapse the two DAO paths into one** context-aware accessor; the context-dropping
   path is removed so the bug cannot recur.
3. **Provision the test tenant via primitives** (`clone_schema` + `copy_workflow` +
   `copy_user`) — *not* by driving the payment-bearing `tenant-signup` workflow, which
   would entangle this with PriceOps (#23).
4. **Tenant context = subdomain via `*.localhost`** in tests, matching production
   subdomain resolution.

## 4. Design

### 4.1 One DAO accessor: always context-aware

There is exactly one way to obtain a DAO — the `dao` helper, which resolves the tenant
from context via `$c->tenant`:

```perl
dao => sub ( $c, $tenant = $c->tenant ) {
    return Registry::DAO->new( url => $ENV{DB_URL}, schema => $tenant );
}
```

`$c->tenant` returns the request's tenant when there is a request, and `registry` when
there is not. That default is **correct and intended** for contextless callers:

- **Controllers mid-request** -> `$self->dao` resolves the acting tenant (or `registry`
  for unauthenticated public requests). The one true path.
- **Jobs / commands / plugin** (no request) -> `$app->dao` resolves `registry`, which is
  exactly what they want: workflow/template *definition* imports and the DBTemplates
  plugin operate on `registry`; per-tenant jobs already name their tenant explicitly
  (`$app->dao($slug)`, iterating `get_all_tenant_schemas`).

So the registry default stays. The bug was never the default — it was that **controllers
had a second, context-dropping path**: `$self->app->dao` hops to the app and silently
abandons the controller's request tenant. Having two accessors (`$self->dao` vs
`$self->app->dao`) is what reopens the bug.

**Collapse to one path:**

1. Migrate every controller `$self->app->dao` -> `$self->dao` (`Workflows.pm` x13,
   `TeacherDashboard.pm` x3, `Webhooks.pm` x2, `Controller.pm` base x2). Existing explicit
   `$self->dao('registry')` lookups (e.g. custom-domain) stay as-is — explicit intent is
   fine.
2. Non-controller callers are unchanged: `$app->dao` -> `registry` is their intended
   behavior.
3. **Guard against recurrence** with a test that fails if `app->dao` appears anywhere
   under `lib/Registry/Controller/`. Controllers have request context; they must use
   `$self->dao`. This makes "two accessors in a controller" structurally impossible going
   forward, without forbidding the legitimate contextless `app->dao` jobs rely on.

**Chicken-and-egg note.** With provisioning done by primitives (3.3), no workflow needs a
special registry pin: `tenant-signup` (out of scope) starts from the registry storefront
with no tenant context, so `$self->dao` resolves it to `registry` naturally.

### 4.2 Copy all workflows on provisioning (kill list drift)

`clone_schema($slug)` clones table structure (including `workflows`, `workflow_steps`,
`workflow_runs`). Tenant provisioning then copies workflow *definitions* into the new
schema. The current `RegisterTenant` copy step uses a **hardcoded list** that has already
drifted (it silently lacks `program-location-assignment`).

Fix the root cause: copy **every** workflow that exists in `registry` into the tenant
schema, derived from the `workflows` table rather than a literal list, excluding only
`tenant-signup` (a tenant never re-runs onboarding inside its own schema). This is
implemented in a reusable provisioning helper (4.4) so both the production path and the
test seed share one definition of "a fully provisioned tenant."

### 4.3 Tenant context by subdomain

Production resolves tenant from `<slug>.example.com` via `_extract_tenant_from_subdomain`,
which rejects bare IPs (hence `127.0.0.1` falls back to `registry` today). In tests we
drive the browser at `http://<slug>.localhost:3001/`; Chromium resolves `*.localhost` to
loopback and the server extracts `<slug>` from the Host header. The `localhost` host
short-circuits the custom-domain DB lookup, which is correct.

**Slug constraint.** Tenant slugs permit `[a-z][a-z0-9_]*` (underscores, not hyphens —
#41). Underscores are not valid DNS hostname characters and Chromium may reject them. To
stay hostname-safe without taking on #41, the lifecycle seed uses an **all-alphanumeric**
slug (lowercase letters + digits, e.g. `lifecycleNNN`). #41 remains the real fix for
human-named tenants and is referenced, not solved, here.

**Validation spike (first task, gating).** Before any other work, a throwaway spike proves
the full path end-to-end: navigate `http://<slug>.localhost:3001/` and assert the server
resolved tenant `<slug>`. If it fails, fall back to the **hybrid** mechanism — `X-As-Tenant`
header for authenticated requests, subdomain only for the unauthenticated storefront. The
design proceeds on subdomain; the hybrid is the defined contingency, not a redesign.

### 4.4 Provisioning via primitives (a shared helper)

`RegisterTenant` already provisions a tenant by calling `clone_schema`, `copy_user`, and
`copy_workflow`. Extract that core into a reusable, PriceOps-free helper —
`Registry::DAO::Tenant->provision($db, %args)` (exact home TBD in planning) — that:
clones the schema, copies seed `program_types`/`templates`, copies the given users, and
copies **all** registry workflows except `tenant-signup` (4.2).

- **Production:** `RegisterTenant` calls the helper instead of its inline, drifting logic.
  (It keeps its own billing/profile handling; only the provisioning mechanics move.)
- **Tests:** the lifecycle seed calls the same helper directly to provision Morgan's
  tenant — no payment workflow, no Stripe, no PriceOps.

This gives one definition of "provisioned tenant" shared by prod and tests, and removes
the `TenantPayment::create_tenant_directly` duplication from the critical path (its
eventual removal is PriceOps work, #23).

### 4.5 Existing-test fallout

The DAO-accessor change touches controllers, jobs, commands, and a plugin, so fallout is
bounded explicitly rather than left open.

**Target set (run all; each must stay green or be fixed):**
- Playwright workflow specs: `tenant-signup`, `jordan-landing-journey`,
  `jordan-admin-dashboard`, `amara-attendance`, `waitlist-flow`, `camp-registration`,
  `parent-dashboard`, `admin-dashboard`, `morgan-program-setup`, `all-workflows-visual`,
  `workflow-layout-visual`, `component-integration`.
- `t/controller/` and `t/dao/` (run as suites) — these exercise Workflows,
  TeacherDashboard, Webhooks, the commands, and the jobs.

**Done-criteria.** The Playwright suite and `t/controller/` + `t/dao/` are green, except
the pre-existing, separately-tracked #227 (`program-listing-filters.t`), which this work
neither fixes nor worsens. The hypothesis: most are unaffected — non-controller callers
keep their registry default unchanged, and the migrated controllers now resolve the acting
tenant (which for context-free or registry-tenant requests is still `registry`). The
specs most likely to *change* behavior are those that drive a workflow as an authenticated
tenant user and previously found their data in `registry`; each is run and any genuine
fallout fixed. If genuinely-affected specs exceed ~3, stop and re-scope with the
maintainer.

## 5. Testing strategy

- TDD at the integration layer using the existing Playwright harness (one Test::PostgreSQL
  DB + one daemon), which imports workflows/templates from disk per run.
- New/extended coverage:
  - A guard test asserting `app->dao` appears nowhere under `lib/Registry/Controller/`
    (the collapse is enforced, not just done once).
  - A unit test asserting `$self->dao` resolves the request tenant within a request and
    `registry` without one (the accessor contract).
  - A provisioning-helper test asserting a provisioned tenant's schema contains all
    non-`tenant-signup` workflows (guards against list drift forever).
  - The subdomain spike, then Morgan's program-setup spec re-pointed at his tenant
    subdomain, asserting project/session/events land in the **tenant** schema.
- Full `t/dao/`, `t/controller/`, and the Playwright suite are the regression gate.

## 6. Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Controller dao migration breaks a spec that relied on registry-resident data | Bounded target set (4.5) with done-criteria; non-controller registry default unchanged; re-scope trigger at >~3 affected specs. |
| Subdomain context unproven in harness (Chromium / `*.localhost` / slug) | Gating spike (4.3); hybrid `X-As-Tenant`+subdomain fallback defined. |
| Provisioning helper diverges from `RegisterTenant` behavior | Single shared helper used by both prod and tests; copies all workflows from the table. |
| Existing tenant data stranded in `registry` orphaned by the switch | Pre-alpha assumption stated (2); migration becomes a prerequisite if it stops holding. |
| Scope creep into PriceOps via `tenant-signup` | Provision via primitives; `TenantPayment`/signup explicitly out of scope (2, 4.4). |

## 7. Sequencing

0. **Subdomain validation spike** (4.3) — gating. Prove `<slug>.localhost:3001` resolves
   to the tenant, or switch to the hybrid fallback. Nothing else starts until settled.
1. **Migrate controllers to `$self->dao`** (4.1): replace every `$self->app->dao` in
   `lib/Registry/Controller/`; add the guard test that keeps `app->dao` out of
   controllers; unit-test the accessor contract. Non-controller callers unchanged.
2. Run `t/controller/` + `t/dao/` after the migration.
3. **Provisioning helper** (4.4) + copy-all-workflows (4.2); `RegisterTenant` delegates to
   it; provisioning test.
4. Run the bounded regression target set (4.5); fix genuine fallout or re-scope.
5. Hand off to Sub-project B (lifecycle E2E in-tenant: seed uses the provisioning helper,
   Morgan drives his journey via his subdomain).

## 8. Open questions

- Are there controller `app->dao` sites that genuinely want `registry` (not the request
  tenant)? Evidence says workflow data should follow the tenant; confirmed per-site during
  migration (step 2), converting any true registry-intent to an explicit `dao('registry')`.
- Best home for the provisioning helper (`Registry::DAO::Tenant->provision` vs a dedicated
  provisioning module). Settled in planning.
- `workflows#index` 500s on an unknown workflow slug (`$workflow->slug` on undef,
  `Workflows.pm:110`) — a robustness gap found during verification. File separately; not
  part of this foundation.
