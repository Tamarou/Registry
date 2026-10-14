# DKIM and tenant sending — units E and F

<!-- ABOUTME: Architectural context for units E and F of the tenant email identity spec: the DKIM record and moving From to the tenant's own domain. -->
<!-- ABOUTME: Every issue in the dkim-tenant-sending milestone points its entrypoints here; A-D are already merged and out of scope. -->

**Spec:** `docs/specs/2026-10-10-tenant-email-identity.md`
**Milestone:** `dkim-tenant-sending`
**Issues:** #21 (custom domains, email half), #480 (the meter, separate)
**Measured at:** `36785c0`, branch `docs/tenant-email-identity-spec`

## Scope

Units **E and F only**. A, B, C and D are merged — #488 (`From` display name
and `Reply-To`), #489 (verification outcome notifications plus the three-state
verification fix), #490 and #491 (the send cap, configurable). Nothing in this
plan re-opens them; where they are named below it is because E or F has to
read or extend what they left.

Both remaining units are **ungated**. Spec decision 2 is settled: `From` moves
to the tenant's domain automatically the moment DKIM verifies, with no opt-in
step.

- **E** — the domain form collects and displays the DKIM record beside the
  routing record, and the page can say "routing verified, mail not".
- **F** — a tenant whose DKIM has verified sends `From` its own domain; one
  whose has not still sends platform-side; and a verification that later breaks
  does not keep sending unsigned.

E must land before F: F has nothing to read until E stores DKIM state.

## What is already built, measured

| | |
|---|---|
| routing verification | `lib/Registry/Job/DomainVerification.pm` polls Render every 15 min (`lib/Registry.pm:1371-1377`), three outcomes — verified / failed / still-pending-with-a-reason |
| the table | `registry.tenant_domains`: `id, tenant_id, domain, status, is_primary, render_domain_id, verification_error, verified_at, created_at, updated_at` (`sql/deploy/tenant-domains.sql`) |
| `status` | **one** `text` column, `CHECK (status IN ('pending','verified','failed'))`. Confirmed: there is no second status column anywhere, and no DKIM, DMARC, SPF or Return-Path string in `lib/`, `sql/`, `templates/` or `docs/` outside the spec itself |
| the admin screens | five routes at `lib/Registry.pm:1067-1071`, `lib/Registry/Controller/TenantDomains.pm`, `templates/admin/domains/index.html.ep`, `templates/admin/domains/dns_instructions.html.ep` |
| the relay | Postmark SMTP, `POSTMARK_SERVER_TOKEN` (`render.yaml:44`, `lib/Registry/DAO/Notification.pm:528-541`) |
| who mail is from | `Notification::_sender_identity` (`lib/Registry/DAO/Notification.pm:167-192`): one query per message, `current_schema()` → tenant name and `tenant_profiles.billing_email`; address stays on the platform domain |
| the send cap | `Registry::Job::SendNotifications::send_allowance` (`:161-180`), 200/day default from `platform_settings`, bulk types only |

## Design rationale

### 1. `status` keeps meaning *routing*. DKIM gets its own column.

The spec flags that one `status` column cannot express "routing verified, mail
not". Verified against the schema: it is a single `text` column with a
three-value CHECK, and it has exactly **two** production readers, which want
different answers:

- `lib/Registry.pm:324` — `if ($td && $td->status eq 'verified')` gates
  host→tenant resolution. This must stay **routing-only**. A school whose DNS
  routes correctly must keep serving its site whether or not it has published a
  DKIM record; letting DKIM reach this line would take a working site down.
- `lib/Registry/Job/SendNotifications.pm:166-173` — `td.status = 'verified'`
  is the condition that returns "no cap". This one is **wrong the moment E
  ships** and is unit F's job to move. The cap exists because an unverified
  tenant is spending the platform's sending reputation; a tenant that has
  verified *routing* and not *DKIM* is still sending under the platform domain,
  so it is still spending our reputation while now being uncapped. F repoints
  this at the DKIM state, which is also exactly what decision 2 means by
  "verification is the single thing that makes a tenant responsible for its own
  reputation" — the verification in question is the DKIM one.

So: add `dkim_status` (and friends) rather than widen or re-interpret `status`.
Every existing reader and every existing assertion in `t/dao/tenant-domain.t`,
`t/job/domain-verification.t`, `t/controller/tenant-domains.t` and
`t/integration/custom-domain-resolution.t` keeps its meaning; only
`send_allowance` deliberately changes which column it reads.

### 2. Mirror the three-state shape, do not invent a fourth.

#489 learned this the hard way and the comment at
`DomainVerification.pm:36-49` says so at length: verification has **three**
outcomes, and `TenantDomain::note_still_pending` records *why* a row is not
verified yet without touching `status`. DKIM inherits that shape —
`dkim_status` in `pending|verified|failed` plus a `dkim_error` that a
still-pending poll can write. A boolean `dkim_verified` would recreate the
defect #489 removed: DNS propagation is slow, and a verifier that can only say
yes/no calls a correct record a failure on the first poll.

### 3. The polling query is the blocker for re-checking.

`DomainVerification::check_pending_domains` selects
`{ status => 'pending' }` (`:58-60`). Two consequences for E and F:

- A routing-verified row never comes back, so its DKIM would never be polled
  at all. The query has to select rows needing **either** check.
- F's "a verification that later breaks does not silently keep sending
  unsigned" needs DKIM re-polled on rows that are *already* DKIM-verified.
  That is a second reason the single `status = 'pending'` predicate cannot
  stand.

The send path itself needs no cache invalidation: `_sender_identity` already
runs a fresh query per message, so whatever the DB says at send time is what
the header says. Keep it that way — do not memoise the sender identity.

### 4. One form, two APIs, and the second one needs a credential we do not have.

Spec decision: both records are collected in the same step so a school files
one DNS ticket. Render verifies routing; Postmark verifies DKIM. They are two
calls behind one form.

The Postmark **Domains** API (`https://api.postmarkapp.com/domains`) is
account-scoped: it authenticates with `X-Postmark-Account-Token`, **not** the
`X-Postmark-Server-Token` / SMTP credential already configured. So E needs a
new secret. Treat the field names below as the expected shape and confirm them
against Postmark's current docs while implementing rather than trusting this
document:

- `POST /domains` `{"Name": "..."}` → an `ID`, the DKIM host and TXT value, and
  the Return-Path CNAME.
- `PUT /domains/{id}/verifyDkim` → the updated record with a DKIM-verified
  flag. This is the three-state verifier; a not-yet answer is `pending`, a
  thrown error is `failed`.
- `GET /domains/{id}` → current state.

`lib/Registry/Service/Render.pm` is the template to copy: a thin Object::Pad
class over `Mojo::UserAgent`, `croak` on a non-success response, injected as a
Mojolicious helper (`lib/Registry.pm:402-412`) so tests can replace it.
`t/service/render-api.t` is the matching mock-UA test pattern — no DB, no live
HTTP, seconds to run.

The new token must be registered in **both** places the platform declares what
it needs, or #459 repeats: `@PRODUCTION_CONFIG` in `lib/Registry.pm:42-55`
(which logs an error per missing variable naming the consequence) and
`render.yaml`'s `registry-config` group. Note that render.yaml env-var changes
have not propagated on their own in the past — the value also has to be set in
the Render dashboard.

### 5. Postmark will refuse an unverified `From`. That is F's real gate.

A relay will not sign, and generally will not accept, mail `From` a domain it
has no verified signature for. So F's gate is the DKIM state, not the routing
state, and the failure mode of getting it wrong is every message bouncing
rather than merely being unsigned. `_sender_identity`
(`lib/Registry/DAO/Notification.pm:167-192`) is the single seam: it already
resolves the tenant per message and already returns a hash the header builder
consumes (`:270-284`). Widening its query to join `registry.tenant_domains` and
pick the tenant address when DKIM is verified is the whole of F's send-side
change.

**Not decided by the spec:** the local part of the tenant address. Reusing the
platform's local part (`noreply@<tenant domain>`) is the smallest change and
needs nothing new collected. Flag it rather than inventing a second field.

### 6. The `domain_verified` notification collides with itself.

Decision 2 says the tenant must be told their mail identity moved, and that
`domain_verified` should carry that news rather than a second notification type
being added. But `Notification::ensure_domain_outcome`
(`lib/Registry/DAO/Notification.pm:572-606`) is idempotent on
`(user_id, type, metadata->>'domain')` — so once a `domain_verified` has been
queued for routing, a later DKIM verification queues **nothing**, silently.

Two shapes, and the first is recommended:

- **Carry the fact in the key.** `ensure_domain_outcome` learns whether mail
  moved, puts it in `metadata`, and includes it in the existence check. One
  message per distinct piece of news, at most two per domain, and
  `Email/Template.pm`'s `domain_verified` body (`:427-459`) gains a mail-moved
  section. Smallest diff; keeps #489's queueing point untouched.
- **Hold until both verify.** One message, both facts — but a tenant whose
  routing verified days before its DKIM hears nothing in the meantime, which is
  the defect #489 exists to fix.

Avoid a new `notification_type` value: per #489's own note, the type is a
Postgres enum, so a new value is a migration whose revert cannot remove it.

### 7. The DNS instructions panel is currently unreachable, and its CSS is inert.

Two live defects in the exact files E must edit:

- `TenantDomains::add` renders `admin/domains/dns_instructions` **directly**
  (`:104`) — a bare partial, no layout, no page chrome — and stashes
  `domain`. Meanwhile `templates/admin/domains/index.html.ep:30` includes that
  partial only `if (stash('new_domain'))`, and **nothing in the codebase ever
  sets `new_domain`**. So the panel never appears on the list page, and the
  post-add response is a fragment. E's "both records in one panel" has to fix
  that path, not add a second record to a panel nobody reaches.
- `dns_instructions.html.ep` is written in Tailwind-style classes
  (`bg-blue-50`, `border-blue-200`, `text-blue-900`, `rounded-lg`, …).
  `grep -c` over `public/css/theme.css` and `public/css/app.css` returns **0**
  for every one of them: they style nothing. `CLAUDE.md` and
  `docs/design-system.md` forbid them. Rewriting the panel means writing
  design-system classes and CSS custom properties. No test enforces this — it
  is a review gate, not a harness gate.

### 8. The manual "Check now" button still has the bug #489 removed from the job.

`TenantDomains::verify` (`:128-150`) marks a domain **failed** on any
non-confirmed Render result, with `'Verification pending'` as the reason — the
precise two-state behaviour `DomainVerification` was fixed to stop doing, and
it writes a terminal status that takes the row out of the polling query. E
edits this file. The DKIM verifier added here must not copy it, and the routing
path in it should be brought into line with `note_still_pending`.

## File structure

**Create**

- `lib/Registry/Service/Postmark.pm` — account-token client: create domain,
  verify DKIM, read state. Shaped on `Service/Render.pm`.
- `t/service/postmark-api.t` — mock-UA unit test, shaped on
  `t/service/render-api.t`.
- `sql/{deploy,revert,verify}/tenant-domains-dkim.sql` — DKIM state on
  `tenant_domains`. Name is a suggestion; `requires: tenant-domains`.
- One test per unit, named as a sentence the way this repo does
  (`t/dao/every-message-says-who-it-is-from.t`,
  `t/dao/a-new-tenant-cannot-spend-our-reputation.t` are the house pattern).

**Modify**

- `sql/sqitch.plan` — append the change; `sql/test-schema.sql` — regenerate
  with `make test-schema` and commit the result.
- `lib/Registry/DAO/TenantDomain.pm` — DKIM fields, and DKIM-state transitions
  mirroring `mark_verified` / `note_still_pending` / `mark_failed`.
- `lib/Registry/Controller/TenantDomains.pm` — register with Postmark on add,
  surface both records, fix the render path from §7, fix the two-state verify
  from §8.
- `templates/admin/domains/dns_instructions.html.ep` — both records in one
  panel, design-system classes.
- `templates/admin/domains/index.html.ep` — a status cell that distinguishes
  routing-verified-mail-not from both-verified.
- `lib/Registry/Job/DomainVerification.pm` — second verifier, widened polling
  query (§3), DKIM outcome reported to the tenant.
- `lib/Registry/DAO/Notification.pm` — `_sender_identity` picks the tenant
  domain when DKIM is verified (F); `ensure_domain_outcome` keyed so the
  mail-moved news is not swallowed (§6).
- `lib/Registry/Email/Template.pm` — `domain_verified` says mail moved.
- `lib/Registry/Job/SendNotifications.pm` — `send_allowance` reads the DKIM
  state, not `status` (§1). **F, not E.**
- `lib/Registry.pm` + `render.yaml` — the new Postmark account token (§4).

## Hazards

- **The revert harness is capped.** `t/database/revert-round-trip.t` asserts
  `@CHANGES <= @SLUGS or die`, and at `36785c0` both lists hold exactly **6**
  entries. Appending a seventh change name without also appending a seventh
  reserved-word slug makes the file **die**, not fail a subtest. Note that
  neither `domain-notification-types` nor `send-cap-setting` was registered, so
  there is recent precedent for leaving a change off the list. Settle this
  deliberately rather than discovering it.
- **Regenerate the dump.** `make test-schema` after the migration, and commit
  `sql/test-schema.sql`. `t/database/schema-dump-current.t` is the guard, and it
  is in the resolution command below.
- **Never hand-run sqitch against production** — `docker-entrypoint.sh` deploys
  on web boot.
- **`t/stripe-live/` must never run locally**; the workstation exports live
  keys. `make test` names directories for this reason.
- **The repo is public.** No customer, school or project names in issues, PRs,
  commits or test fixtures.
- **Acceptance shell:** never write a bare `grep -c … ` expecting `0` — grep
  prints `0` and **exits 1**, so a verifier reading exit codes fails on a
  passing condition. Write `test "$(grep -c …)" = 0`.
- **Playwright.** `t/playwright/custom-domains.spec.js` already asserts on the
  DNS-instructions page, including the exact comment that the partial renders a
  "DNS Setup Required" heading. E changes that page, so the **full** Playwright
  suite is the gate, not the one spec.

## Resolution command

```
STRIPE_SECRET_KEY=ci_placeholder_not_a_stripe_key carton exec prove -lr -j8 \
  t/database/schema-dump-current.t t/service/render-api.t t/dao/tenant-domain.t \
  t/controller/tenant-domains.t t/job/domain-verification.t \
  t/dao/every-message-says-who-it-is-from.t \
  t/dao/a-new-tenant-cannot-spend-our-reputation.t \
  t/integration/custom-domain-resolution.t t/dao/email-templates-domains.t \
  t/dao/notifications.t t/dao/notification-postmark-transport.t
```

Measured in this worktree at `36785c0`: **127 wallclock seconds**, 11 files, 79
tests, `Result: PASS`. That is 42% of the 300-second ceiling that
`git zhi milestone edit --state complete` imposes, with the slowest single file
(`schema-dump-current.t`, 116s alone) already included and overlapped by `-j8`.
New test files added by E and F land inside that same window — the mock-UA
Postmark test needs no database at all. Add the new files to this command as
they are written.

`t/database/revert-round-trip.t` is **deliberately excluded**: it was measured
here at over **7 minutes without finishing** and was killed. It alone would make
the milestone impossible to close. The full suite (`make test`, ~28 minutes) is
the branch gate before a PR, not the milestone resolution command.

## Open — do not invent answers

- **Spec decision 4 is still open:** whether a domain step belongs in the
  signup relay, or the `/admin/domains` nav entry is enough. Custom domains are
  not a day-one want for every tenant. E and F must not add a signup step.
- **Return-Path / custom bounce domain.** Postmark offers it as a second CNAME
  alongside DKIM, and nothing in the codebase handles bounces at all. DMARC
  aligns on DKIM alone, so it is not required for the spec's goal.
  Recommendation: leave it out and file it, rather than widening E's form to a
  third record. Needs a call.
- **The local part of the tenant `From`** (§5).
- **#480** — the meter that replaces `send_allowance`'s source — stays separate,
  as do **#485**, **#423** and **#428**.
