# Tenant email identity and deliverability

**Status:** spec; A, B, C, D delivered (#488, #489, #490). **E and F remain**, and are now UNGATED — decision 2 is settled.
**Date:** 2026-10-10
**Issues:** #21 (custom domains, email half), #480 (metering), #438 (provisioning limit, closed)

## Why now

Registry started sending mail last week. Until #484 shipped a drainer,
`Notification->create` wrote rows that nothing ever delivered — no `->send` on the
enrollment path, no sweep of `sent_at IS NULL`, no task. Every message ever
queued sat unsent.

So a set of problems that were latent are now things families see. The first
message a parent receives from Registry today arrives from
`noreply@tinyartempire.com`, with no indication which school it concerns and no
address that reaches anybody if they reply. That is the whole of it:

```perl
# lib/Registry/DAO/Notification.pm:184
From => $ENV{NOTIFICATION_FROM_EMAIL} || 'noreply@registry.example.com',
```

A bare address. No display name, no `Reply-To`.

Meanwhile a school that has put `register.myschool.org` in a browser — which
#21's existing work makes possible — will expect confirmations from that domain
too, and DMARC will not pass on a DKIM record the school never published.

## Current state, measured

| | |
|---|---|
| relay | Postmark, via `POSTMARK_SERVER_TOKEN` (`render.yaml`); `Notification::send_email` builds the MIME itself |
| custom domains | **built**: `registry.tenant_domains` (table, `is_primary`, `render_domain_id`, `verification_error`), verification through the **Render API** every 15 min, host→tenant resolution at `lib/Registry.pm:313-333` gated on `status eq 'verified'`, five admin routes, `/admin/domains` in the nav, `dns_instructions.html.ep` |
| DKIM / DMARC / SPF | **nothing.** `grep -rniE "dkim\|dmarc\|spf\|return-path" lib/ sql/ templates/ docs/` is empty |
| tenant identity in mail | partial. `Notification::_template_vars` already threads `tenant_name` for `magic_link_invite`, `email_verification`, `passkey_*` (`:95,109,115`). The parent-facing types — `enrollment_confirmation`, `waitlist_joined` — do **not** |
| an office address | `tenant_profiles.billing_email` exists. Nothing else. No `contact_email`, no `reply_to` |
| send cap | none. Rate limiting is HTTP-level only (auth, magic links, provisioning) |
| provisioning cap | `use constant PROVISIONINGS_PER_HOUR => 20` (`TenantPayment.pm:296,326`), per IP per hour, production only. The control that closed #438 |
| domain outcome emails | `domain_verified` and `domain_verification_failed` are **fully written** (`Email/Template.pm:427,460`, HTML + text) and **nothing creates either**, nor are they values in the `notification_type` enum |

## Decisions already made

- **Interim identity before DKIM:** keep `From` on the platform domain, put the
  tenant's name in the display name, set `Reply-To` to the school. Raised in
  #21's comments, agreed by perigrin. This is worth shipping on its own and
  first: one header line, no DNS dependency, improves every message.
- **One form, two records.** The routing/TLS record and the DKIM record are
  collected in the same "verify your domain" step so a school files one DNS
  ticket. They have different verifiers — Render for routing, Postmark for DKIM
  — so this is one form over two APIs, not one call.
- **Volume limits are entitlements.** A send cap and the provisioning limit are
  the same question — *how much is this tenant entitled to?* — and belong in
  `pricing_configuration` with a meter behind them (#480), not in `use
  constant`. The pattern is already stated in the file that holds the constant.
  **This does not block shipping a cap**: ship it as a constant if that is what
  is ready, confined to one function that answers "may this tenant send?", so a
  meter can replace it rather than argue with it.
- **A notification can learn its own tenant.** `Registry::DAO::Notification` is
  unqualified and resolves through the tenant `search_path`, so
  `SELECT current_schema()` gives the slug and `registry.tenants` gives the
  name. No new column needed to put a display name on a message.

## Open decisions — do NOT invent answers to these

1. ~~**Which address is `Reply-To`?**~~ **SETTLED 2026-10-10, and the question
   was wrong.** The spec claimed `billing_email` is "for billing". The signup
   form labels that very field **"Contact Email"** (`profile.html.ep:55`), and
   `Workflows.pm:493` reports it as `'Contact email'` when missing — the column
   name is a misnomer, not a different address, and the form has only ever asked
   for one. perigrin's call once corrected: use what is already collected rather
   than ask a solo operator for the same address twice. A tenant wanting billing
   and parent replies to differ needs a profile-edit screen, which does not
   exist and is separate work.
2. ~~**Does `From` move to the tenant's domain automatically once DKIM
   passes?**~~ **SETTLED 2026-10-10: it moves.** Automatically, on verification,
   with no opt-in step. So unit F has no gate left, and two consequences follow
   that unit E must build for:

   - **A tenant's mail identity changes without anyone pressing anything.** The
     moment DKIM verifies, every subsequent message is from a different domain.
     That wants telling -- #489 already queues `domain_verified`, so the natural
     move is for that message to say mail is moving too, rather than adding a
     second notification.
   - **The send cap's premise lapses at the same instant.** `send_allowance`
     already returns "no cap" for a tenant with a verified domain, so a tenant
     gains its own `From` and its uncapped allowance from one event. That is
     coherent, and worth stating: verification is the single thing that makes a
     tenant responsible for its own reputation.
3. ~~**What is the cap's number, and which mail does it apply to?**~~
   **SETTLED 2026-10-10.** 200 a day, and only the tenant-composed bulk types
   (`message_announcement`, `message_update`) — auth, transactional and
   emergency mail are exempt, each on stated grounds. perigrin accepted the
   figure on condition it be configurable, which #491 does: it is a
   `platform_settings` row Alex can change without a deploy, with the constant
   as its default and `0` kept distinct from unset.
4. **Does a domain step belong in the signup relay** or is the `/admin/domains`
   nav entry enough? Custom domains are not a day-one want for every tenant.

## Work

Session-sized, vertical, each independently shippable unless marked.

### A. Every message says which tenant it is from — **DONE (#488)**
Thread `tenant_name` into the parent-facing notification types and put it in the
`From` display name.
- **paths:** `lib/Registry/DAO/Notification.pm`
- **commands:** `carton exec prove -lv t/dao/notifications.t t/dao/notification-postmark-transport.t t/dao/waitlist-join-is-in-writing.t`
- **done when:** an `enrollment_confirmation` and a `waitlist_joined` built in a
  tenant schema both render a `From` whose display name is that tenant's name,
  asserted against the generated MIME header rather than the metadata; a
  notification in the `registry` schema still sends with the platform name.

### B. A reply reaches the school — **DONE (#488)**, with A
Add `Reply-To`.
- **paths:** `lib/Registry/DAO/Notification.pm`, possibly a migration for a new
  tenant contact field
- **done when:** a parent-facing message carries a `Reply-To` that is the
  tenant's chosen address, and a message with no such address configured omits
  the header rather than emitting an empty one.

### C. Verification tells the tenant what happened — **DONE (#489)**
Wire `domain_verified` and `domain_verification_failed`, which already exist as
templates and reach nobody.
- **paths:** `sql/{deploy,revert,verify}/domain-notification-types.sql`,
  `sql/sqitch.plan`, `lib/Registry/DAO/Notification.pm`,
  `lib/Registry/Job/DomainVerification.pm`
- **commands:** `carton exec prove -lv t/job/domain-verification.t`; `make test-schema`
- **done when:** a domain transitioning to `verified` queues exactly one
  `domain_verified` for the tenant's admin and the drainer sends it; a
  transition to `failed` queues `domain_verification_failed` carrying
  `verification_error`; re-running the job queues neither a second time.
- **note:** follow #484 exactly — `notification_type` is a Postgres enum, so a
  new value is a migration, and the enum value cannot be removed on revert.

### D. A new tenant cannot spend the platform's reputation — **DONE (#490)**
Cap outbound mail per tenant until its own domain is verified.
- **paths:** `lib/Registry/DAO/Notification.pm` or
  `lib/Registry/Job/SendNotifications.pm`, one new function
- **done when:** a tenant over the cap has its queued mail held rather than
  dropped — the row stays unsent and findable, not deleted; a tenant with a
  verified domain is never capped; the cap is read from one function so #480 can
  replace its source.
- **why it matters:** #438 closed with a per-**IP provisioning** limit, which
  throttles tenant *creation* and says nothing about sending. Signup is
  scriptable by #438's own account.

### E. The domain form asks for the DKIM record too *(needs open decision 2)*
Collect and display the DKIM record beside the routing record.
- **paths:** `lib/Registry/Controller/TenantDomains.pm`,
  `templates/admin/domains/dns_instructions.html.ep`,
  `lib/Registry/Service/Postmark.pm` (new), migration for DKIM state on
  `tenant_domains`
- **done when:** adding a domain shows both records in one panel, and the page
  distinguishes "routing verified, mail not" from "both verified" — those are
  different states for a school and the current single `status` cannot express
  both.

### F. Mail comes from the tenant's own domain *(blocked by A, E; needs decision 2)*
- **done when:** a tenant whose DKIM has verified sends with `From` on its own
  domain; one whose has not still sends platform-side; and a verification that
  later breaks does not silently keep sending unsigned.

## Critical chain

`A → F` and `E → F`. **C and D are independent of everything** and are the
quickest route to a tenant noticing an improvement.

**A, B, C and D are done** (#488, #489, #490, with #491 making D's cap
configurable). What remains is **E and F**, the DKIM work, and **both are now
ungated**: `From` moves automatically on DKIM verification (decision 2,
settled). This is the chain to refine.

Three things the delivered units found that E and F will meet again:

- **Unit C needed a prerequisite the spec did not anticipate.** The verification
  job could not tell "DNS still propagating" from "failed": it marked any
  non-confirmed result terminal, and the polling query selects `status =
  'pending'`, so a correct domain was failed minutes after being added and never
  rechecked. There was no honest transition to notify on until that was fixed.
  Verification now has **three** outcomes, and `note_still_pending` records a
  reason without touching status. E and F add a second verifier (Postmark) to
  the same flow, so they inherit that three-state shape rather than a boolean.
- **The single `status` column cannot express "routing verified, mail not"**,
  which is exactly the state a school sits in between units E and F. Unit E
  already names this; it is now the live constraint.
- **Unit D's cap is narrower than "email volume"**: only
  `message_announcement` and `message_update`, the types a tenant composes
  freely. Auth mail, transactional mail and emergencies are exempt on stated
  grounds. If F moves `From` to a tenant domain, the cap's premise changes --
  a tenant sending under its OWN domain is no longer spending our reputation,
  which is why `send_allowance` already returns "no cap" for a verified domain.

Three things #488 found in that block, worth knowing before touching it again:
a non-ASCII display name was emitted as raw 8-bit bytes; #484's own subjects
interpolate a session name, so `Café Kids` put raw bytes in a `Subject`; and a
`To` phrase of `Smith, Jones and Co` was unquoted, which reads as two
addresses. All three are fixed, and the three cases do not combine — an
encoded-word must not be quoted, a phrase with specials must be, plain ASCII is
left alone.

## Not in this chain

Raised alongside this work and deliberately separate — unrelated concerns that
would make the chain incoherent:

- **#485** five DAOs double-encode non-ASCII into `jsonb` (two on the money
  path). Arguably more urgent than any of the above: it corrupts accented names
  in payment metadata, which is not an edge case for after-school programs.
- **#423** the workflow progress indicator has never rendered.
- **#428** ~190s of unattributed client-side time in `morgan.spec.js`;
  provisioning, server time and `networkidle` are all eliminated, wants a trace.
- **#480** the meter itself.

## Constraints

The Registry repo is PUBLIC: no customer or project names in issues, PRs or
commits. Gate for every unit: `carton exec prove -lr -j8 t/` green after the
last edit, plus the full Playwright suite for anything user-facing. One PR per
unit. Migrations deploy themselves on web boot via `docker-entrypoint.sh` —
never hand-run sqitch against production. The workstation exports live
`sk_live_` keys; `t/stripe-live/` must never run locally.
