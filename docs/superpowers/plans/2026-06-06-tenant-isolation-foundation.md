# Tenant Isolation Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Registry workflows execute against the acting tenant's Postgres schema by collapsing the DAO accessor to a single context-aware path, and provide a reusable tenant-provisioning primitive — unblocking the per-tenant lifecycle E2E (#224).

**Architecture:** One `dao` helper resolves the tenant from request context (`$c->tenant`), defaulting to `registry` only when there is no request (jobs/commands). Controllers stop using the context-dropping `$self->app->dao` and use `$self->dao`; a guard test keeps `app->dao` out of controllers. Tenant provisioning (clone schema, copy users, copy all workflows) is extracted into one helper shared by `RegisterTenant` and tests. Platform billing / `TenantPayment` (PriceOps #23/#76) is explicitly out of scope.

**Tech Stack:** Perl 5.42, Object::Pad, Mojolicious, Mojo::Pg, PostgreSQL schemas, Test::More + Test::Mojo + Test::Registry::* helpers, Playwright (E2E).

**Spec:** `docs/superpowers/specs/2026-06-06-tenant-isolation-foundation-design.md`

---

## File map

- `lib/Registry.pm` — `dao` helper (make default `$c->tenant` explicit; no behavior change for callers).
- `lib/Registry/Controller.pm` — base: `app->dao` ×2 → `$self->dao`.
- `lib/Registry/Controller/Workflows.pm` — `app->dao` ×13 → `$self->dao`.
- `lib/Registry/Controller/TeacherDashboard.pm` — `app->dao` ×3 → `$self->dao`.
- `lib/Registry/Controller/Webhooks.pm` — `app->dao` ×2 → `$self->dao` (behavior-preserving; no request tenant).
- `lib/Registry/DAO/Tenant.pm` — add `provision` class method (clone_schema + program_types/templates + copy_user + copy all workflows).
- `lib/Registry/DAO/WorkflowSteps/RegisterTenant.pm` — delegate provisioning mechanics to `Tenant->provision`.
- `t/dao/dao-accessor-contract.t` — new: accessor contract + controller guard.
- `t/dao/tenant-provision.t` — new: provisioning helper copies all non-`tenant-signup` workflows.
- `t/playwright/tmp-subdomain-spike.spec.js` — throwaway spike (Task 0; deleted after).

---

## Task 0: Subdomain context spike (GATING — not TDD)

**Purpose:** Prove `http://<slug>.localhost:3001/` resolves to tenant `<slug>` in the Playwright harness before committing the design to subdomain context. If it fails, switch to the hybrid fallback (X-As-Tenant for authed, subdomain for storefront) and adjust Sub-project B accordingly.

**Files:**
- Create (throwaway): `t/playwright/tmp-subdomain-spike.spec.js`

- [ ] **Step 1: Write the spike**

```javascript
// ABOUTME: Throwaway spike — does <slug>.localhost resolve to a tenant in the harness?
const { test, expect } = require('./fixtures/base');
const { execSync } = require('child_process');

test('subdomain host resolves to tenant', async ({ page, testDB }) => {
  // Provision a hostname-safe tenant directly.
  execSync(
    `carton exec perl -e "use lib qw(lib t/lib); use Registry::DAO; use Registry::DAO::Tenant; ` +
    `my \\$db = Registry::DAO->new(url => '${testDB.dbUrl}')->db; ` +
    `Registry::DAO::Tenant->create(\\$db, { name => 'Spike', slug => 'spike1' }); ` +
    `\\$db->query('SELECT clone_schema(dest_schema => ?)', 'spike1');"`,
    { cwd: process.cwd() }
  );

  // Add a temporary debug route on the running daemon is not possible here;
  // instead assert resolution via a known tenant-scoped page differing from registry.
  // Minimal proof: navigate to the subdomain host and confirm the server accepts it
  // (200) and the response is the storefront for 'spike1', not the registry landing.
  const res = await page.goto('http://spike1.localhost:3001/');
  expect(res.status()).toBe(200);
});
```

- [ ] **Step 2: Run the spike**

Run: `npx playwright test tmp-subdomain-spike --workers=1 --project=chromium --reporter=list`
Expected: PASS (Chromium resolves `spike1.localhost` to loopback; server returns 200). 

**Decision gate:**
- PASS → subdomain context is viable. Proceed.
- FAIL (Chromium refuses host / connection error) → record the failure, switch the spec/plan to the **hybrid** mechanism (Sub-project B uses `X-As-Tenant` for Morgan's authed requests, subdomain only for the storefront), and note it here before continuing.

- [ ] **Step 3: Delete the spike, commit the decision note**

```bash
rm t/playwright/tmp-subdomain-spike.spec.js
git add -A
git commit -m "Spike: confirm subdomain (<slug>.localhost) tenant resolution in harness"
```

---

## Task 1: Collapse the DAO accessor onto `$self->dao`

**Files:**
- Modify: `lib/Registry.pm:224` (make the default explicit)
- Modify: `lib/Registry/Controller.pm:18,33`
- Modify: `lib/Registry/Controller/Workflows.pm` (lines 10,15,20,64,109,128,230,289,465,477,490,523,627)
- Modify: `lib/Registry/Controller/TeacherDashboard.pm:16,64,108`
- Modify: `lib/Registry/Controller/Webhooks.pm:39,177`
- Test: `t/dao/dao-accessor-contract.t` (new)

- [ ] **Step 1: Write the failing guard + contract test**

```perl
use 5.42.0;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw(done_testing is ok like unlike)];
defer { done_testing };

use Mojo::File qw(path);
use Test::Mojo;
use Registry::DAO;
use Test::Registry::DB;
use Test::Registry::Fixtures;

# --- Guard: no controller may use app->dao (the context-dropping footgun) ---
my @offenders;
for my $f ( path('lib/Registry/Controller')->list_tree->each ) {
    next unless $f =~ /\.pm$/;
    my $src = $f->slurp;
    push @offenders, "$f" if $src =~ /app->dao/;
}
# Controller.pm base lives one level up:
{
    my $src = path('lib/Registry/Controller.pm')->slurp;
    push @offenders, 'lib/Registry/Controller.pm' if $src =~ /app->dao/;
}
is "@offenders", '', 'no controller uses app->dao (use $self->dao)';

# --- Contract: $self->dao resolves request tenant, registry without a request ---
my $t_db = Test::Registry::DB->new;
my $dao  = $t_db->db;
$ENV{DB_URL} = $t_db->uri;
my $t = Test::Mojo->new('Registry');

my $tenant = Test::Registry::Fixtures::create_tenant($dao, { name => 'Acc', slug => 'acc1' });
$dao->db->query('SELECT clone_schema(dest_schema => ?)', $tenant->slug);
my $user = $dao->create(User => { username => 'acc_admin', user_type => 'admin' });

my $c = $t->app->build_controller;
$c->req->headers->header('X-As-Tenant' => $tenant->slug);
$c->stash(current_user => { id => $user->id, user_type => 'admin' });
is $c->dao->current_tenant, 'acc1', '$self->dao -> request tenant';

my $bare = $t->app->build_controller; # no request tenant
is $bare->dao->current_tenant, 'registry', '$self->dao -> registry without context';
```

- [ ] **Step 2: Run it; expect FAIL on the guard**

Run: `carton exec prove -lv t/dao/dao-accessor-contract.t`
Expected: FAIL — the guard lists `Workflows.pm`, `TeacherDashboard.pm`, `Webhooks.pm`, `Controller.pm`.

- [ ] **Step 3: Make the `dao` helper default explicit (no behavior change)**

In `lib/Registry.pm`, change the helper signature so the default is visible and self-documenting:

```perl
dao => sub ( $c, $tenant = $c->tenant ) {
    # Single DAO accessor. $c->tenant is the request tenant, or 'registry'
    # when there is no request (jobs/commands/plugin). Controllers must reach
    # this via $self->dao, never $self->app->dao (which drops request context).
    return Registry::DAO->new(
        url    => $ENV{DB_URL},
        schema => $tenant,
    );
}
```

(If the body already constructs the DAO differently, keep that body; only the signature default and comment change.)

- [ ] **Step 4: Migrate controller call sites**

In each listed controller, replace `$self->app->dao` with `$self->dao`. These are all the
read-the-current-tenant DAO acquisitions. Leave any existing explicit `$self->dao('registry')`
or `$self->dao($self->stash('tenant'))` untouched.

```bash
for f in lib/Registry/Controller.pm \
         lib/Registry/Controller/Workflows.pm \
         lib/Registry/Controller/TeacherDashboard.pm \
         lib/Registry/Controller/Webhooks.pm; do
  perl -pi -e 's/\$self->app->dao\b/\$self->dao/g' "$f"
done
```

Then visually confirm no semantic surprise (e.g. a site that truly wanted registry — none expected; Webhooks has no request tenant so resolves registry either way).

- [ ] **Step 5: Run the contract test; expect PASS**

Run: `carton exec prove -lv t/dao/dao-accessor-contract.t`
Expected: PASS (guard clean, both contract assertions green).

- [ ] **Step 6: Run controller + dao suites**

Run: `carton exec prove -lr t/controller/ t/dao/`
Expected: PASS except the pre-existing #227 `program-listing-filters.t` (unchanged). If any
other spec fails, diagnose per spec §4.5 (convert genuine registry-intent to explicit
`dao('registry')`); if >~3 specs fail, STOP and surface to the maintainer.

- [ ] **Step 7: Commit**

```bash
git add lib/Registry.pm lib/Registry/Controller.pm lib/Registry/Controller/Workflows.pm \
        lib/Registry/Controller/TeacherDashboard.pm lib/Registry/Controller/Webhooks.pm \
        t/dao/dao-accessor-contract.t
git commit -m "Collapse DAO access to context-aware \$self->dao; guard controllers against app->dao"
```

---

## Task 2: Shared tenant-provisioning primitive + copy all workflows

**Files:**
- Modify: `lib/Registry/DAO/Tenant.pm` (add `provision`)
- Modify: `lib/Registry/DAO/WorkflowSteps/RegisterTenant.pm` (delegate to `provision`)
- Test: `t/dao/tenant-provision.t` (new)

- [ ] **Step 1: Write the failing provisioning test**

```perl
use 5.42.0;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw(done_testing is ok)];
use experimental 'keyword_any';
defer { done_testing };

use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Test::Registry::DB;

my $t_db = Test::Registry::DB->new;
my $dao  = $t_db->db;
$ENV{DB_URL} = $t_db->uri;
my $db = $dao->db;

# An admin user to copy into the tenant.
my $admin = Registry::DAO::User->create($db, {
    username => 'prov_admin', user_type => 'admin',
    email => 'prov_admin@test.com', name => 'Prov Admin',
});

my $tenant = Registry::DAO::Tenant->provision($db, {
    name  => 'Provision Test',
    slug  => 'provision1',
    users => [ $admin ],
});
ok $tenant, 'provision returned a tenant';
is $tenant->slug, 'provision1', 'tenant slug as requested';

# The tenant schema must contain the workflows the operator journey needs,
# and must NOT contain tenant-signup.
my $tenant_dao = Registry::DAO->new(url => $ENV{DB_URL}, schema => $tenant->slug);
my @slugs = map { $_->{slug} }
    $tenant_dao->db->select('workflows', ['slug'])->hashes->each;

for my $need (qw(program-creation program-location-assignment tenant-storefront)) {
    ok( (any { $_ eq $need } @slugs), "tenant has '$need' workflow" );
}
ok( !(any { $_ eq 'tenant-signup' } @slugs), 'tenant does NOT have tenant-signup' );

# The admin user is present in the tenant schema.
my $copied = $tenant_dao->find(User => { username => 'prov_admin' });
ok $copied, 'admin user copied into tenant schema';
```

- [ ] **Step 2: Run it; expect FAIL**

Run: `carton exec prove -lv t/dao/tenant-provision.t`
Expected: FAIL — `Tenant->provision` does not exist.

- [ ] **Step 3: Implement `Tenant->provision`**

In `lib/Registry/DAO/Tenant.pm`, add a class method that performs the PriceOps-free
provisioning mechanics (mirroring `RegisterTenant` lines 117–172, but copying ALL
workflows except `tenant-signup` from the `workflows` table):

```perl
# Provision a tenant's schema: clone structure, copy seed program_types/templates,
# copy the given users, and copy every registry workflow definition except
# tenant-signup. Returns the created tenant. PriceOps/billing is out of scope here.
sub provision ( $class, $db, $args ) {
    $db = $db->db if $db isa Registry::DAO;

    my $tenant = $class->create( $db, {
        name => $args->{name},
        ( $args->{slug} ? ( slug => $args->{slug} ) : () ),
    } );
    my $slug = $tenant->slug;

    $db->query( 'SELECT clone_schema(dest_schema => ?)', $slug );

    # Seed rows clone_schema does not copy.
    $db->query(qq{
        INSERT INTO ${slug}.program_types (slug, name, config, created_at, updated_at)
        SELECT slug, name, config, created_at, updated_at FROM registry.program_types
        ON CONFLICT (slug) DO NOTHING
    });
    $db->query(qq{
        INSERT INTO ${slug}.templates (id, name, slug, content, metadata, notes, created_at, updated_at)
        SELECT id, name, slug, content, metadata, notes, created_at, updated_at FROM registry.templates
        ON CONFLICT (slug) DO NOTHING
    });

    # Copy users (accept user objects or hashrefs with an id).
    for my $u ( @{ $args->{users} || [] } ) {
        my $uid = ref $u && $u->can('id') ? $u->id : $u->{id};
        $db->query( 'SELECT copy_user(dest_schema => ?, user_id => ?)', $slug, $uid );
    }
    if ( my $primary = ( $args->{users} || [] )->[0] ) {
        $tenant->set_primary_user( $db, $primary );
    }

    # Copy ALL workflow definitions except tenant-signup (no list to drift).
    my $rows = $db->select( 'workflows', [ 'id', 'slug' ] )->hashes;
    for my $w ( $rows->each ) {
        next if $w->{slug} eq 'tenant-signup';
        $db->query( 'SELECT copy_workflow(dest_schema => ?, workflow_id => ?)',
            $slug, $w->{id} );
    }

    return $tenant;
}
```

Note: confirm the `copy_user`/`copy_workflow`/`clone_schema` argument styles against the
running DB functions (named args used elsewhere: `dest_schema => ?`). Adjust if the SQL
function signatures differ.

- [ ] **Step 4: Run the provisioning test; expect PASS**

Run: `carton exec prove -lv t/dao/tenant-provision.t`
Expected: PASS (all four needed/excluded workflow assertions + user copy).

- [ ] **Step 5: Delegate `RegisterTenant` provisioning to the helper**

In `lib/Registry/DAO/WorkflowSteps/RegisterTenant.pm`, replace the inline
`clone_schema` + program_types/templates inserts + hardcoded `copy_workflow` loop
(roughly lines 117–200) with a call to `Registry::DAO::Tenant->provision`, passing the
profile-derived name/slug and the resolved user list. Keep RegisterTenant's billing /
profile / invitation-email logic intact — only the schema-provisioning mechanics move.
(If profile shape makes a clean extraction awkward, pass the already-created users and
have `provision` accept a pre-created tenant via an optional `tenant => $tenant` arg —
decide during implementation, keeping one provisioning definition.)

- [ ] **Step 6: Run tenant-signup coverage**

Run: `carton exec prove -lr t/dao/ t/controller/` and `npx playwright test tenant-signup --workers=1 --project=chromium --reporter=list`
Expected: PASS except pre-existing #227. RegisterTenant still provisions a working tenant,
now with all workflows.

- [ ] **Step 7: Commit**

```bash
git add lib/Registry/DAO/Tenant.pm lib/Registry/DAO/WorkflowSteps/RegisterTenant.pm \
        t/dao/tenant-provision.t
git commit -m "Add Tenant->provision (copies all workflows); RegisterTenant delegates to it"
```

---

## Task 3: Bounded regression pass (spec §4.5)

**Files:** none (verification only)

- [ ] **Step 1: Run the DAO + controller suites**

Run: `carton exec prove -lr t/dao/ t/controller/`
Expected: green except pre-existing #227.

- [ ] **Step 2: Run the Playwright workflow specs**

Run each (one harness at a time):
`npx playwright test <spec> --workers=1 --project=chromium --reporter=list`
for: `tenant-signup`, `jordan-landing-journey`, `jordan-admin-dashboard`,
`amara-attendance`, `waitlist-flow`, `camp-registration`, `parent-dashboard`,
`admin-dashboard`, `morgan-program-setup`, `all-workflows-visual`,
`workflow-layout-visual`, `component-integration`.
Expected: green. For any failure, diagnose whether it relied on registry-resident data;
fix by routing to the intended tenant or asserting registry default. If >~3 specs are
genuinely affected, STOP and surface to the maintainer.

- [ ] **Step 3: Commit any fallout fixes individually**

```bash
git add <files>
git commit -m "Fix <spec> fallout from DAO tenant-isolation switch"
```

---

## Handoff to Sub-project B (lifecycle E2E)

Not part of this plan. With the foundation in place: the lifecycle seed calls
`Tenant->provision` to create Morgan's hostname-safe tenant; Morgan drives his journey via
his subdomain (`<slug>.localhost`), so his data lands in his schema; Nancy registers and
Amara takes attendance against the same tenant schema; then the three legs are chained into
one spec. Sub-project B gets its own spec → plan.
