# ABOUTME: Architecture Decision Record holding perigrin's rulings on workflow reach, tenant-authored workflows and the storefront choice.
# ABOUTME: Steps 5 and 6 of the PriceOps day-one chain read these rulings instead of each waiting on its own answer.

# ADR 004: How Workflows Reach Tenants, and Where the Storefront Choice Lives

**Status:** Accepted

**Date:** 2026-11-22

**Asked:** in the Claude Code session that executes the `priceops-day-one` chain,
<https://claude.ai/code/session_01V7rs98q3bwA7Cs9ZBpVuL5>, first in the
consolidated message of questions after chain-review round 1, then one question
at a time on 2026-11-22. perigrin answered each in that session; his answers
are quoted verbatim below.

---

## (a) How a later workflow reaches a tenant holding Solo

On day one the platform sells exactly one offer, Solo. Offer versions are
immutable, and each offer version buys one resource (`01a20417-1146`). Options
as `01a20415-69c6` states them: a new Solo version naming a set of workflows
(needs offers that buy several resources, which 1146 forbids today); each
workflow its own $0 platform offer (breaks "exactly one offer"); or a
data-driven set (breaks immutability).

Ruling: (a) A new Solo version lists the workflow set and holders move to it; the upgrade rule waits for real holders
Source: "(a) New Solo version" https://claude.ai/code/session_01V7rs98q3bwA7Cs9ZBpVuL5

Consequences:
- `01a20417-1146` (one resource per offer version) is relaxed before step 6
  so that an offer version may buy a set. Day one still sells a
  single-resource Solo.
- How existing holders move to a new version (automatically when the new
  version is a pure superset, always automatically, or by opting in) is not
  decided. Asked about it, perigrin replied "Are there v1 holders?". There are
  none today, and at most SACP after step 6. He then ruled "Yes, defer it
  (Recommended)": the rule is decided when the first holder outside SACP
  exists.

## (b) Whether tenant-authored workflows need a run entitlement

Step 6 lets a tenant run a workflow only if it holds an entitlement to it. A
workflow the tenant authored was not bought from anyone. Options as
`01a20415-69df` states them: the right to create workflows covers running
them; authoring creates an entitlement the tenant grants itself; or they do
not run until the platform offers them.

Ruling: (b) The right to create workflows covers running the workflows the tenant authored
Source: "(a) Create right covers run (Recommended)" https://claude.ai/code/session_01V7rs98q3bwA7Cs9ZBpVuL5

The option letter in his answer is the letter the option carried when asked;
this record files it under question (b). Consequence: step 6's gate admits a
workflow the tenant holds an entitlement to, or one the tenant authored.
Authoring is itself gated by the `workflow-creation` entitlement.

## (c) Where a tenant's storefront choice lives as data

Today `storefront_workflow` (`lib/Registry.pm:1233-1235`) compares the slug
to `registry`: `registry` gets `registry-storefront` and every other tenant
gets `tenant-storefront`. Options: a column on `registry.tenants`, a
per-tenant setting, the run right the tenant holds, or the presence of the
workflow in the tenant's schema.

Ruling: (c) The run right the tenant holds: a tenant's storefront is the storefront workflow it is entitled to run
Source: "The run right held (Recommended)" https://claude.ai/code/session_01V7rs98q3bwA7Cs9ZBpVuL5

Consequence: the slug comparison stays until step 6's gate exists. It is then
replaced by a lookup of the storefront workflow the tenant holds. `registry`
holds `registry-storefront` and studios hold `tenant-storefront`, granted with
Solo.
