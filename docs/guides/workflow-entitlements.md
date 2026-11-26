---
stability: 1
covers:
  - lib/Registry.pm
  - lib/Registry/WorkflowDivergence.pm
  - lib/Registry/Command/workflow.pm
  - lib/Registry/DAO/Tenant.pm
  - lib/Registry/DAO/Entitlement.pm
---

# How Tenants Gain and Run Workflows

How a tenant comes to hold a workflow, why a workflow URL answers 403 or 404,
how the platform adds a workflow, and how to read the divergence report. How
the gate and the copy work inside is in
[Workflows](../architecture/workflows.md) ("Who may run a workflow" and
"Multi-tenant Support"). This guide does not repeat it.

Who each section serves ([personas](../personas/README.md)):

| Persona | Role here | Sections |
|---|---|---|
| [Alex](../personas/alex.md) | The admin of the platform tenant `registry`: ships workflows, runs the divergence report | All |
| [Rosa](../personas/rosa.md) | The admin of a studio tenant such as SACP | 1, 2, 3, 6 |

The rulings this relies on are in
[ADR 004](../decisions/004-step-6-workflow-reach-and-storefront.md).

---

## 1. The rule

A tenant runs a workflow only while it holds an **in-effect** entitlement, from
`registry`, to the resource named `run:<slug>`. That is the workflow's run
right. Nothing else counts:

- the name must match exactly (no pattern, other case or trailing space);
- the entitlement must be active and its period must cover now;
- it must be recorded in `registry`. A right a tenant records in its own
  schema grants nothing, and neither does another tenant's.

The right may come from a single-resource offer version or from a version
that buys a set of resources, as Solo v2 does.

`registry` follows the same rule. It holds a run right to each of its own
workflows. It never passes by being called `registry`.

## 2. How a tenant gains a workflow

A tenant gains a workflow in one way only: by **accepting a platform offer**
whose version grants the workflow's run right. Accepting creates the
entitlement and copies the workflow into the tenant's schema in the same
transaction. It copies the workflow's steps, templates, roles or public mark,
and the outcome definitions its steps use. If any copy fails, the tenant gets
neither the entitlement nor any partial workflow.

Never grant a workflow with a migration, a CLI command or a hand copy into a
tenant's schema. A copy without a run right is refused by the gate anyway
(section 3).

### What Solo grants

Solo v2 is the offer a studio accepts. The migration `solo-grants-workflow-set`
published it. Its stored set is:

- `payment processing`;
- a run right for each non-draft workflow in `workflows/` when that migration
  was written, except `tenant-signup` and `registry-storefront`. That is 35
  workflows, `__default__` and `tenant-storefront` among them.

`tenant-signup` and `registry-storefront` are `registry`'s alone: accepting
never copies them, even under an offer that granted them.

The set is data stored on the offer version. Nothing works out "every
workflow" when a tenant accepts. A workflow shipped later reaches a studio
only when a new Solo version lists it (section 4).

### When it happens

In the shipped code a studio accepts Solo once, at signup. The `tenant-signup`
workflow's payment step provisions the tenant and accepts the chosen offer
together. Provisioning copies no workflow of its own: a new tenant holds
copies of exactly the workflows its accepted offer grants, and a tenant
provisioned without accepting an offer holds none.

There is no screen for an existing tenant to accept an offer later. A
development database's SACP is re-created by signing up, as
[the seed README](../../sql/seed/README.md) describes.

### A tenant that already has a copy

When the tenant already has a copy of a granted workflow, accepting compares
it with `registry`'s (section 5) and:

| Copy | What accepting does | Reported as |
|---|---|---|
| No copy | copies the platform's | `copied` |
| Same as the platform's | keeps it | `identical` |
| Differs, `Ruling: replace <tenant>/<slug>` | drops the copy and copies the platform's | `replaced` |
| Differs, `Ruling: merge <tenant>/<slug>` | keeps it; it needs a hand merge | `kept: merge ruling, needs a hand merge` and the differences |
| Differs, no ruling | keeps it | `kept: diverged, no ruling` and the differences |

The rulings are read from `docs/reviews/tenant-workflow-divergence.md` in the
deployed tree (section 6).

A `replace` of a copy that already has runs is refused by the database, and
the whole accept rolls back.

### Workflows a tenant writes

A workflow the tenant wrote through `workflow-creation` was not bought, so it
has no run right of its own. Per ADR 004 ruling (b), "Create right covers
run": the gate admits it while the tenant holds `run:workflow-creation`.

The gate counts a slug as the tenant's own only when `registry` has no
workflow of that slug. The comparison ignores case and surrounding spaces. A
copy of a slug `registry` does have always needs that slug's own run right,
whatever the tenant has edited in it.

A written workflow gets the roles of `workflow-creation` itself (admin and
staff), and it cannot be marked public.

The storefront (section 3) never falls back on the create right.

## 3. Why a workflow URL answers 403 or 404

The gate (`require_workflow_role` in `lib/Registry.pm`) guards every entry to
a workflow:

- `/<slug>`;
- each step URL `/<slug>/<run>/<step>`, including Stripe's return to one;
- a callcc into another workflow;
- the routes that name their workflow in the route rather than the URL (`/`,
  `/admin/dashboard`, `/admin/templates`, the drop and transfer approvals).

A refused request creates no run. Work through this checklist in order. The
gate asks the questions in this order, and the first "no" decides.

1. **Is there anything at that slug?** A slug with no workflow row in this
   tenant's schema and no `<slug>/index` template is a **404**, before the
   gate runs.
2. **Does the tenant hold the run right?** If the request's tenant does not
   hold `run:<slug>` in effect (section 1), and the slug is not one it wrote
   under `run:workflow-creation` (section 2), the answer is **403** for
   everyone. That includes admins, anonymous visitors to a public workflow,
   and a step POST on a run started before the right ended.
   - The tenant is the one the host resolves to. A form field, header or
     cookie naming another tenant borrows nothing.
   - If the lookup itself fails, the answer is also 403, and the error is
     logged: the gate fails closed.
3. **Does the tenant's own copy say who may run it?** The gate reads the
   workflow row in this tenant's schema, never `registry`'s.
   - If the row has the public mark, anyone is admitted.
   - If the row has a non-empty `roles` list, go to step 4.
   - If the row has neither, or there is no row at all, the answer is
     **403** for everyone. `tenant-signup` on a studio's host is refused this
     way.
4. **Does the visitor hold one of those roles?** The gate reads the visitor's
   role in this tenant, from their membership (ADR 005, ruling 4).
   - An anonymous visitor is sent to `/auth/login`. A request that asks for
     JSON or sends `X-Requested-With` gets a 401 instead.
   - A signed-in user with another role gets **403**.

Two more cases answer 404:

- A step URL whose run does not belong to that workflow in this tenant is a
  **404**. A run of an admin-only workflow cannot be continued through a
  public slug.
- At `/`, the storefront is the first of `registry-storefront` and
  `tenant-storefront` that the tenant holds an **explicit** run right to.
  `registry` holds both and gets `registry-storefront`. A studio holds
  `tenant-storefront` through Solo. A tenant holding neither gets a **404**
  at `/`.

Runs no person is waiting on are not gated. The `continue_workflow_run`
Minion job, and the Stripe Connect webhook, drive a run without passing
through these routes, and the job does not re-check run rights. Neither does
a workflow that a step starts internally: the entry to the outer workflow is
its only gate.

## 4. Adding a workflow to the platform

For Alex, shipping a new `workflows/<slug>.yml`:

1. **Declare who may run it.** The YAML must declare either a non-empty
   `roles:` list or `public: true`, never both. Import refuses both.
   `t/security/workflow-roles-cover-every-workflow.t` fails the build for a
   shipped workflow with neither, and the gate would refuse it to everyone.
2. **Import it into `registry`.** On import, `registry` gains `run:<slug>`
   automatically (migration `registry-run-right-at-import`). From then on the
   workflow runs on the platform host. A workflow present when
   `workflow-run-entitlements` deployed got its right from that backfill.
3. **Publish it to tenants through an offer.** Per ADR 004 ruling (a), "New
   Solo version": a new Solo version lists the workflow, and studios gain the
   workflow by accepting it. Until a new Solo version lists the slug, no
   studio is granted it, and `t/priceops/solo-lists-every-shipped-workflow.t`
   fails the build. A YAML with `draft: true` is exempt from that test.

Changing who may run an *existing* workflow needs a sqitch migration that
updates `registry` and every tenant schema. Editing a YAML's roles alone
changes only fresh databases. See "Who may run a workflow" in
[Workflows](../architecture/workflows.md).

## 5. The divergence report

Migrations that reset a workflow change only `registry`'s copy. A tenant's
copy can therefore fall behind, or be edited away from the platform's. To see
how each tenant's copies differ from `registry`'s, run:

```bash
carton exec ./registry workflow divergence registry
```

The command is read-only: it only reads, and its connection is read-only. It
covers every tenant in `registry.tenants`, except `registry` itself. The
output is Markdown, with one `## <tenant>` section per tenant, in slug order.
Each section says either `No differences.` or lists one line per difference.
Each line names the field and both values:

| Line | Meaning |
|---|---|
| `` `<slug>`: only in the tenant `` | The tenant has a slug `registry` lacks (a workflow it wrote, or a kept copy) |
| `` `<slug>`: missing from the tenant `` | `registry` has it, the tenant does not |
| `` `<slug>`: the tenant holds a copy; provisioning never copies it `` | The tenant has `tenant-signup` or `registry-storefront` |
| `` `<slug>`: steps: registry `…`; tenant `…` `` | The step order differs |
| `` `<slug>`: roles: … `` / `` public: … `` | Who may run it differs |
| `` `<slug>` step `<step>`: class: … `` | That step's class differs |
| `` `<slug>` step `<step>`: template: … `` | That step's template name differs |
| `` `<slug>` step `<step>`: template content: … `` | The template's exact content differs, shown as a sha256 prefix and byte length |
| `- error: …` | That tenant's schema is missing or unreadable; the other tenants are still compared |

The report expects two things and does not list them:

- the absence of `tenant-signup` and `registry-storefront` from a tenant;
- a tenant's `tenant-storefront` `program-listing` step having no template.
  Provisioning unlinks it on purpose (#173, #229). A tenant step linked to
  some other template is still reported.

"Missing from the tenant" is measured against all of `registry`'s workflows,
not against what the tenant holds a run right to.

## 6. Rulings: what accepting does to an existing copy

perigrin rules on each difference the report finds. The rulings are recorded
in [the divergence review](../reviews/tenant-workflow-divergence.md), one line
each, on a line of its own:

```text
Ruling: replace <tenant>/<slug>
Ruling: merge <tenant>/<slug>
```

- `replace`: when the tenant next accepts an offer granting `<slug>`, its
  copy is dropped and the platform's copied.
- `merge`: the copy is kept, and the accept's result says it needs a hand
  merge.
- Any other line rules nothing, including `Ruling: none needed`. A copy that
  differs with no ruling is kept.

Accepting reads these lines from that file as deployed, so a ruling takes
effect when the commit that records it is deployed. The record of
2026-11-25 found no studio tenants in production, so it holds no `replace` or
`merge` rulings.

## 7. Open questions

These are filed and not yet decided. The guide describes only today's code.

- `01a21632-694e`: the create right lets a tenant rebuild a platform workflow
  under a new slug and run it without that workflow's run right.
- `01a215ed-1ea8`: there is no admin path to publish a new Solo version that
  buys a set. Today only a sqitch migration can, as `solo-grants-workflow-set`
  did.
- `01a215ed-1ef6`: whether platform-operator workflows, such as
  `platform-fee-refund-exception`, stay in Solo's set.
- How existing holders move to a new offer version is deferred by ADR 004
  ruling (a) until the first holder outside SACP exists.
