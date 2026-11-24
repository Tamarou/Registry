# SACP Stripe Connect Onboarding

Operator runbook for wiring SACP's Stripe Standard connected account into
Registry so SACP can take paid enrollments.

Registry makes **direct charges**: every sale is charged on the selling
tenant's own Stripe account, with a `Stripe-Account` header naming it, and the
platform's share is the charge's `application_fee_amount`. There is no
`transfer_data`, no `on_behalf_of` and no `reverse_transfer`. The customer,
payment method, refunds and disputes all live on SACP's account. See
[ADR 003](../decisions/003-direct-charges-stripe-source-of-truth.md) for the
decision.

This runbook covers one tenant. Repeat it for any future tenant that needs
paid enrollment. The platform tenant (`registry`) is set up by
[the platform tenant bootstrap runbook](platform-tenant-bootstrap.md), not by
this one.

Placeholders:

| Placeholder | Means |
|---|---|
| `acct_PLATFORM` | Tamarou's own (platform) Stripe account id |
| `acct_XXXX` | SACP's connected account id |
| `<sacp-slug>` | SACP's `registry.tenants.slug` |
| `<platform-host>` | the host Registry is served on |
| `sk_test_...`, `whsec_...` | a Stripe secret key and a webhook signing secret |

Never paste a real key or signing secret into a ticket or this file.

---

## 1. Create / locate SACP's Standard connected account

The normal path is self-service: an admin of SACP opens **Admin → Billing**
(`/admin/billing`) and presses connect. `POST /admin/billing/connect` creates a
Standard account on Stripe, writes its id to
`registry.tenants.stripe_connect_account_id` before redirecting, and sends the
admin to Stripe's hosted onboarding. When Stripe sends them back to
`/admin/billing/return`, Registry reads the account and writes
`stripe_charges_enabled` and `stripe_details_submitted`.

If the account has to be found or finished by hand instead:

1. Log in to the platform Stripe account (`acct_PLATFORM`).
2. Go to **Connect → Accounts** and open SACP's Standard account (or create
   one).
3. Complete onboarding.

   **Check:** the account overview shows `charges_enabled: true` and
   `details_submitted: true`. If it shows "Restricted" or either flag is false,
   SACP must finish Stripe's identity and bank-account steps first.

---

## 2. Record the connected account and check SACP's platform terms

1. Find SACP's slug:

   ```sql
   SELECT slug, name, stripe_connect_account_id,
          stripe_charges_enabled, stripe_details_submitted
     FROM registry.tenants WHERE name ILIKE '%sacp%';
   ```

   **Check:** one row. If `stripe_connect_account_id` is already `acct_XXXX`
   and both flags are true, the self-service flow did this step; go to step 3.

2. Only if the row does not name the account yet, record it:

   ```sql
   UPDATE registry.tenants
      SET stripe_connect_account_id = 'acct_XXXX',
          stripe_charges_enabled    = true,
          stripe_details_submitted  = true
    WHERE slug = '<sacp-slug>';
   ```

   **Check:** `UPDATE 1`. Re-run the step 1 query and see `acct_XXXX` with both
   flags true.

   After this the flags are kept current by `account.updated` on the Connect
   endpoint (section 3), which updates only the tenant whose
   `stripe_connect_account_id` is the account the event is for. Hand edits are
   needed only before that endpoint exists.

3. Confirm SACP holds a platform entitlement to payment processing. A payment
   is created only for a tenant with one in effect; there is no fallback to
   Free or 0 (section 6, "Revenue share rate"):

   ```sql
   SELECT o.name, p.kind, p.fraction, e.state
     FROM registry.entitlements e
     JOIN registry.tenants t ON t.id = e.holder_tenant_id
     JOIN registry.offer_versions v ON v.id = e.offer_version_id
     JOIN registry.offers o ON o.id = v.offer_id
     JOIN registry.resources r ON r.id = v.resource_id
     JOIN registry.offer_version_payment_plans p
       ON p.offer_version_id = v.id AND p.id = e.payment_plan_id
    WHERE r.name = 'payment processing'
      AND t.slug = '<sacp-slug>';
   ```

   **Check:** one `active` row, `Solo`, `0.025`. Solo v1 is described in
   [section 9 of the bootstrap runbook](platform-tenant-bootstrap.md#9-solo-v1-and-the-platforms-0-offer-to-itself).

Changing `stripe_connect_account_id` later does not move existing payments.
Each payment copies the account into `metadata.stripe_account_id` when it is
created, and every intent, retrieve, cancel and refund for that payment goes to
that account.

---

## 3. Webhook configuration

Registry has **two** Stripe webhook endpoints, each with its own signing
secret. A delivery signed for one never verifies at the other.

| Endpoint | Stripe setting | Secret variable | Receives |
|---|---|---|---|
| `POST /webhooks/stripe` | **Events on your account**, on `acct_PLATFORM` | `STRIPE_WEBHOOK_SECRET` | events on the platform's own account: tenant billing, `application_fee.refunded`, and the platform tenant's own sales |
| `POST /webhooks/stripe/connect` | **Events on Connected accounts**, on `acct_PLATFORM` | `STRIPE_CONNECT_WEBHOOK_SECRET` | events on sellers' accounts, SACP's included |

Both secrets are in the `registry-stripe` env group (`render.yaml`), shared by
the web service and the worker. With `MOJO_MODE=production`, startup logs
`STRIPE_CONNECT_WEBHOOK_SECRET is not set in production: ...` at error when it
is missing, and the Connect endpoint then answers every delivery with 500
`Webhook verification not configured`.

### 3.1 The platform endpoint

1. In the Stripe dashboard on `acct_PLATFORM`, go to **Developers → Webhooks**
   and open (or add) the endpoint `https://<platform-host>/webhooks/stripe`,
   listening to **Events on your account**.
2. Select these events:
   - `customer.subscription.updated`, `customer.subscription.deleted`,
     `customer.subscription.trial_will_end`, `invoice.payment_succeeded`,
     `invoice.payment_failed` (tenant billing)
   - `application_fee.refunded` (the platform's fee on a seller's charge was
     returned; see section 6)
   - `payment_intent.succeeded` (the platform tenant's own sales, which are
     made on `acct_PLATFORM` and settle in the `registry` schema)
3. Copy the endpoint's signing secret into `STRIPE_WEBHOOK_SECRET`.

   **Check:** in the endpoint's delivery log, recent deliveries answer 200. A
   400 `Invalid signature` means the secret in `STRIPE_WEBHOOK_SECRET` is not
   this endpoint's.

### 3.2 The Connect endpoint

1. On `acct_PLATFORM`, **Developers → Webhooks → Add endpoint**:
   - URL `https://<platform-host>/webhooks/stripe/connect`
   - Listen to **Events on Connected accounts**
   - API version `2024-12-18.acacia`. The handler reads an invoice's
     subscription from the top-level `invoice.subscription`, which is where
     that version puts it.
2. Select these events:
   - `payment_intent.succeeded`
   - `invoice.paid`, `invoice.payment_failed`, `invoice.voided`,
     `invoice.marked_uncollectible`
   - `account.updated`
   - `refund.updated`
   - the refund, dispute and customer events Registry stores (`STRIPE_MOVES`
     in `Webhooks.pm`): `charge.refunded`, `charge.refund.updated`,
     `refund.*`, `charge.dispute.*`, `customer.*`
3. Copy this endpoint's signing secret into `STRIPE_CONNECT_WEBHOOK_SECRET`
   and redeploy.

   **Check:** the startup log has no
   `STRIPE_CONNECT_WEBHOOK_SECRET is not set in production` line, and the
   endpoint's delivery log shows 200s, not 500 or 400.

### 3.3 What the Connect endpoint does with an event

**The tenant is found by `event.account`**, the top-level account Stripe puts
on every Connect event, matched exactly against
`registry.tenants.stripe_connect_account_id`. Metadata is never used to pick
the tenant: the seller can edit metadata on its own account. If a
`payment_intent.succeeded` names a different `tenant_slug` in metadata, the
account wins and a warning is logged.

| Event | What happens |
|---|---|
| any event for an account no tenant names | 200 `OK (no tenant)`, logged, not claimed; except the refund, dispute and customer events below, which are stored with no tenant |
| `payment_intent.succeeded` for the intent Registry stored on the payment | settles the payment in SACP's schema: completes it, records the fee, finalizes the enrollments |
| `payment_intent.succeeded` for a payment Registry did not make (no or non-UUID `metadata.payment_id`, no such payment, or not the intent Registry stored), such as SACP's own Terminal or counter sale | 200, logged, ignored |
| `payment_intent.succeeded` for an intent Registry created and later replaced (listed in the payment's `metadata.superseded_intent_ids`) | nothing settles, staff are alerted, and the `superseded_refund` job refunds it in full (section 6) |
| `invoice.paid`, `invoice.payment_failed`, `invoice.voided`, `invoice.marked_uncollectible` | the subscription is read from SACP's account with `expand[]=schedule`; only an invoice whose schedule Registry recorded, with `billing_reason` `subscription_create`, `subscription_cycle` or `subscription_update`, marks an instalment row |
| `account.updated` | mirrors `charges_enabled` and `details_submitted` onto the tenant row, when the account in the event is the one it was delivered for |
| `refund.updated` for a refund Registry holds as pending | settles that refund (section 6, "Refunds") |
| other refund, dispute and customer events (`charge.refunded`, `charge.refund.updated`, `refund.*`, `charge.dispute.*`, `customer.*`) | **stored, not applied**: the row in `registry.webhook_events` keeps the account, tenant and payload, with `processed_at` NULL. Nothing in Registry changes. |
| anything else | claimed, logged as not handled, 200 |

To see what has been stored unapplied:

```sql
SELECT stripe_event_id, event_type, account, tenant_id, received_at
  FROM registry.webhook_events
 WHERE processed_at IS NULL
 ORDER BY received_at DESC;
```

A refund or dispute SACP makes in its own Stripe dashboard shows up here and
nowhere else in Registry. Act on it by hand until Registry applies these
events.

### 3.4 Instalment invoices Stripe collected but Registry did not record

An instalment invoice billed before its schedule was recorded is retried for a
day and then dropped. The `instalment_reconcile` job closes that gap: for every
tenant with a Stripe account, it lists the paid invoices of each schedule that
still has a `pending` or `failed` row, on that tenant's account, and settles
them as `invoice.paid` would.

`instalment_reconcile` is queued when the web server starts, if none is
already waiting, to run an hour later. It does not queue itself again.

1. Run it now on the worker or web host:

   ```bash
   ./registry minion job -e instalment_reconcile
   ```

2. **Check:** the instalment rows now show `completed` with
   `metadata.stripe_invoice_id` set:

   ```sql
   SELECT id, instalment_seq, status, metadata->>'stripe_invoice_id' AS invoice
     FROM "<sacp-slug>".payments
    WHERE stripe_schedule_id = '<sub_sched_...>'
    ORDER BY instalment_seq;
   ```

3. Read the log for `instalment_reconcile: ... matches no owed row`. That line
   means Stripe collected an invoice that no payment row records. Settle it
   with SACP by hand.

### 3.5 The platform's own account

The platform tenant sells like any seller: its row names `acct_PLATFORM` and
its payments carry `Stripe-Account: acct_PLATFORM`. Stripe accepts a
`Stripe-Account` header naming the API key's own account: the
`RESULT:` line of `t/stripe-live/platform-account-header.t` records it accepted
on 2026-11-23 (API `2024-12-18.acacia`, test mode) for creating and confirming
a payment intent, creating a customer and retrieving the intent, and records a
header naming a nonexistent account refused. So the payment step sends the
header for every seller, the platform included, and has no special case. If
Stripe ever refuses it, that live test fails.

The platform's own sales take no fee because `registry` holds a 0% entitlement,
and a zero fee is omitted. Setting that up is covered by
[the bootstrap runbook](platform-tenant-bootstrap.md), not here.

---

## 4. Deploy checklist

Perform these steps in order. Do not skip the row-count check — the
`tenant-scoped-payments` migration moves rows out of `registry.payments` into
per-tenant payment tables and will abort loudly on a pre-flight condition:

| Pre-flight | Error trigger | Remediation |
|---|---|---|
| Payer-residency | A registry-resident tenant payment's payer does not exist in the tenant schema | `SELECT copy_user(dest_schema => '<slug>', user_id => '<id>');` for each missing user |

**Expected prod state before deploy:** approximately zero tenant-tagged payment
rows in `registry.payments` (pre-alpha). Confirm actual counts with perigrin by
querying the production DB against the spec risk table before deploying.

```sql
-- Query before deploy -- should return 0 or a small number to review
SELECT metadata->>'tenant_slug' AS tenant, COUNT(*)
FROM registry.payments
WHERE metadata->>'tenant_slug' IS NOT NULL
GROUP BY 1;
```

**Deploy steps:**

```bash
# Apply both new sqitch changes
carton exec sqitch deploy

# Confirm changes applied
carton exec sqitch status
```

The deploy applies `tenant-stripe-connect` (adds Connect columns to
`registry.tenants`) and then `tenant-scoped-payments` (backfills payment tables
into every existing tenant schema, repoints `enrollments.payment_id` FKs
tenant-locally, and moves any registry-resident tenant payment rows).

**Post-deploy smoke check** (`<hostname>` is the tenant's domain;
`$DATABASE_URL` must already be exported in the shell):

```bash
# Health endpoint must return green
curl https://<hostname>/health

# Optional: confirm tenant schema has payment tables
psql $DATABASE_URL -c "\dt <sacp-slug>.pay*"
```

Then run one test-mode paid enrollment on a test tenant (see step 5).

---

## 5. Live validation (test mode before going live)

Use Stripe **test** keys and a Stripe test connected account. Do not use live
keys: `Registry::Service::Stripe->from_env` refuses an `sk_live_` key unless
`MOJO_MODE=production`. Configure both endpoints of section 3 in test mode and
set:

```bash
export STRIPE_SECRET_KEY=sk_test_...                # test secret key
export STRIPE_WEBHOOK_SECRET=whsec_...              # test platform endpoint's secret
export STRIPE_CONNECT_WEBHOOK_SECRET=whsec_...      # test Connect endpoint's secret
```

1. Point a test tenant at a test connected account (sections 1 and 2, with
   `<test-slug>` and the test account `acct_XXXX`).

   **Check:** section 2 step 3's query returns one active entitlement.

2. Complete one paid enrollment for that tenant with test card
   `4242 4242 4242 4242`, and note the amount in cents.

   **Check:**

   ```sql
   SELECT id, status, amount_cents, platform_fee_cents,
          platform_offer_version_id, platform_payment_plan_id,
          stripe_payment_intent_id, metadata->>'stripe_account_id' AS account
     FROM "<test-slug>".payments ORDER BY created_at DESC LIMIT 1;
   ```

   `status = 'completed'`, `account = 'acct_XXXX'`, both platform ids set.
   `platform_fee_cents` is the amount times 0.025 (Solo v1), in whole cents,
   rounded half to even; for a zero fee it is 0. The enrollment is in
   `"<test-slug>".enrollments`, and `registry.payments` has no row with this
   id.

3. Read the intent **on the connected account**:

   ```bash
   curl -s https://api.stripe.com/v1/payment_intents/<pi_...> \
     -u "$STRIPE_SECRET_KEY:" -H "Stripe-Account: acct_XXXX"
   ```

   **Check:** `status` is `succeeded`, `application_fee_amount` equals
   `platform_fee_cents` (the field is absent when the fee is 0), and there is
   no `transfer_data` and no `on_behalf_of`. For an instalment payment,
   `customer` is set, and that customer is on `acct_XXXX` too. The same request
   **without** `Stripe-Account` fails with `No such payment_intent`: the charge
   is not on the platform account.

4. Read the fee **on the platform account** (no `Stripe-Account`):

   ```bash
   curl -s https://api.stripe.com/v1/application_fees \
     -u "$STRIPE_SECRET_KEY:" -G -d charge=<ch_... from latest_charge>
   ```

   **Check:** one fee whose `amount` equals `platform_fee_cents` and whose
   `account` is `acct_XXXX`.

5. Confirm the event arrived at the Connect endpoint:

   ```sql
   SELECT event_type, processed_at
     FROM registry.webhook_events
    WHERE event_type = 'payment_intent.succeeded'
    ORDER BY received_at DESC LIMIT 1;
   ```

   **Check:** `processed_at` is set, and the Connect endpoint's (not the
   platform endpoint's) delivery log in Stripe shows the event answered 200.

6. Run the live suite (section 7).

   **Check:** it passes. Its refund tests make a full and a partial refund on
   the tenant account and assert the refund is found with `Stripe-Account` and
   the fee's `amount_refunded` stays 0.

Once all six checks pass, SACP can be switched from test to live keys.

---

## 6. Platform rate and refund behavior

### Revenue share rate

The tenant's platform entitlement is the source of its rate. Each tenant holds
an entitlement in `registry.entitlements` to an offer version for the resource
"payment processing", with one of that version's payment plans. Signup grants
it. The rate is the `fraction` on that payment plan
(`registry.offer_version_payment_plans`). Solo v1 carries `0.025` (2.5%).

`Registry::PriceOps::PlatformTerms::platform_terms_for_tenant($db,
$tenant_slug)` resolves the entitlement in effect now. It returns the offer
version id, the payment plan id and the rate as an exact decimal string
(`"0.025"`, never a float). A tenant with no entitlement in effect is refused
by name: there is no fallback to Free or to 0, and no payment row is written.

`Registry::DAO::Payment` fixes the rate when the payment is created and keeps
it in the payment's metadata, so every retry sends the same
`application_fee_amount` (integer cents, rounded half-up). When the fee is
recorded, the payment row is stamped with the terms it was charged under:
`platform_offer_version_id` and `platform_payment_plan_id`.

### Refund policy

A refund reads the refund policy of the offer version stamped on the payment,
not the tenant's current entitlement. The policy is `policies->'refund'` on
`registry.offer_versions`, read through
`Registry::DAO::Payment::stamped_platform_terms`.

- An ordinary refund sends no `refund_application_fee`, so the platform keeps
  its fee.
- The platform's fee can be returned only when the stamped version's refund
  policy is `keep_fee_with_admin_exception` (Solo v1's).
  `Registry::DAO::Payment::refund_platform_fee_async` does this. It refuses,
  before calling Stripe, any payment with no stamp or under any other policy.
  Nothing in the application calls it yet.

### Clearing a stranded `refund_pending` payment

`refund_pending` means the platform owes a refund it has not yet issued, and
the refund call itself failed after the settlement transaction had already
committed. Two different things put a row here, and they leave DIFFERENT
enrollment state behind:

- **The seat was gone.** A capacity re-check at capture found the child's seat
  taken, put them on the session's waitlist, and recorded the debt. The seat is
  released, so this payment holds a `cancelled` enrollment row with
  `drop_reason = 'seat_unavailable_refunded'`, and the child has a `waiting`
  row in `waitlist` for that session.
- **The seat was already theirs.** The child already held a live seat from a
  DIFFERENT payment -- a free enrolment, an admin add, an earlier purchase --
  so this cart paid for something it did not need. Nothing is queued; this
  payment gets a `cancelled` enrollment row with
  `drop_reason = 'duplicate_seat_refunded'` recording that it bought a seat it
  never received, and the live seat still belongs to whoever paid for it first.

Both leave a `cancelled` row, so the status alone does not tell them apart --
`drop_reason` does. Check which case you are in before deciding anything:

```bash
psql $DATABASE_URL -c \
  "SELECT e.status, e.drop_reason, e.payment_id, e.student_id
     FROM \"<sacp-slug>\".enrollments e
    WHERE e.payment_id = '<payment_id>'"
```

`seat_unavailable_refunded` is the first case, `duplicate_seat_refunded` the
second. A child in the first case is in the queue for that session and will be
offered the next seat that frees up; the refund you are about to issue does not
take them out of it.

**No rows at all is a third case**, and it means the share could not be
computed: the marker is written only once the debt it stands for resolves, so an
unresolvable share leaves the payment `refund_pending` with nothing recorded
against it. Such a row always carries `metadata.refund_manual_review`, which is
why Step 1 searches on that as well as on status. Treat it as the manual-review
path below -- decide the amount by hand -- and expect `refund_owed_cents` to be
0 rather than the share you are about to send. It is deliberately still
retryable: fix the underlying line item and the next delivery settles it
automatically.

In the first two cases the refund owed is this payment's share for that child,
and the procedure below is the same.

**Stripe's redelivery does not heal this.** The dedup claim in
`registry.webhook_events` commits in the same transaction as the settlement, by
design, so the retry is deduplicated away. The money is captured, the
enrollment is correct, and the refund is owed to nobody's queue. There is no
automated reader for this state until Leg 3 ships `ProcessRefunds`. Until then
it is cleared by hand, using the procedure below.

#### Step 1: Find the stranded rows

`payments` is tenant-scoped -- these rows are in the tenant's schema, not in
`registry`. Query per tenant:

```bash
psql $DATABASE_URL -c \
  "SELECT id, amount_cents, refund_owed_cents, refunded_cents,
          jsonb_pretty(refund_increments) AS increments,
          metadata->'refund_manual_review' AS manual_review,
          metadata->'refund_last_failure' AS last_failure,
          stripe_payment_intent_id, completed_at
     FROM \"<sacp-slug>\".payments
    WHERE status = 'refund_pending'
       OR jsonb_array_length(COALESCE(metadata->'refund_manual_review', '[]'::jsonb)) > 0
       OR metadata ? 'refund_last_failure'
    ORDER BY completed_at"
```

The second predicate matters: a debt that could not be recorded at all -- a
share the code could not compute, or one on a row that had already reached a
terminal refund status -- is flagged in `metadata.refund_manual_review` without
moving the status. Searching on status alone misses exactly the rows nobody else
is going to catch.

`refund_owed_cents` is what is still owed and `refunded_cents` is what has
already gone back. `refund_increments` is the authority for **what to send**: a
JSON array of debts, each with its own `seq`, `cents`, and `settled_at`. Send
one refund per increment whose `settled_at` is null, **for that increment's own
`cents`** -- never for the `refund_owed_cents` total. The increments sum to the
total by construction, and sending the total is how one debt gets paid twice.

`metadata.refund_last_failure` is the most recent refund attempt on this
payment that failed -- a capacity increment (paid from the payment step or the
webhook) or an approved drop's refund
(`Registry::DAO::Payment::record_refund_failure`). It holds `classification`,
`message`, and `at` (epoch seconds). Read `classification` before anything else:

| `classification` | Means | Do |
|---|---|---|
| `not_sent` | The request never left Registry. No money moved. | Fix the cause in `message`, then Step 3. Step 2 is still cheap insurance. |
| `unknown` | Stripe refused it, or the response was lost. Money may have moved. | Step 2 first, always. |

**A drop's refund is not a capacity increment: Steps 3 and 4 do not apply to
it.** A drop has no increment, its row is usually `completed` rather than
`refund_pending` (the last predicate above is what lists it), and Step 3's
`refund:capacity:...` key would not match the drop's own. Run Step 2 first.
Then retry by resubmitting the drop's refund step, which reuses the key
`refund:drop:<payment_id>:<enrollment_id>`, so Stripe returns the earlier refund
rather than sending a second. If you must refund by hand instead, use that same
key and then set the enrollment's `refund_status = 'processed'`; otherwise a
later re-approval of the drop refunds the family again.

The field is cleared automatically when a later refund on the same payment
succeeds, so a row that still carries it has had no successful refund since that
failure. A `pending` refund does not clear it. One failure is kept per payment,
so it is a lead, not the queue: a successful refund for one child on a shared
cart clears it even if another child's refund is still owed. The queue is
`status`, `refund_increments` and, for drops, the enrollment's
`refund_status = 'pending'`. When you settle a row by hand (Step 4), remove it
yourself:

```bash
psql $DATABASE_URL -c \
  "UPDATE \"<sacp-slug>\".payments
      SET metadata = metadata - 'refund_last_failure'
    WHERE id = '<payment_id>'"
```

A row with `refund_manual_review` set reached a state the automatic path could
not resolve and needs a human decision on the amount. Two causes, and they call
for different actions:

- **No line item for the child.** `calculate_enrollment_total` skips a child
  whose plan returns no price, so they ride along in the cart with nothing
  behind them. Decide the amount from what the family was actually charged.
- **A nonsense share.** The line item exists but is negative, which means a
  pricing plan is misconfigured -- `percentage_discount` is unbounded, so a
  plan above 100 produces one. Fix the plan as well as the refund, or it will
  keep happening. Do not simply refund the negative number.

Such a row stays `refund_pending` even when
`refund_owed_cents` is zero and every increment is settled, deliberately: that
is the only way it stays in this query's results until someone acts on it.

#### Step 2: List refunds before issuing one

**Always list first.** The failure that stranded the row may have happened
after Stripe accepted the refund, so the debt can already be discharged:

```bash
curl -s https://api.stripe.com/v1/refunds \
  -u "$STRIPE_SECRET_KEY:" \
  -G -d payment_intent=<stripe_payment_intent_id>
```

**No `Stripe-Account` header.** These are destination charges made *on the
platform account* -- `Registry::DAO::Payment` sets
`transfer_data[destination]` and `on_behalf_of` rather than acting as the
connected account, and `Registry::Service::Stripe::_request_async` never sends
`Stripe-Account`. Adding the header queries an account on which the
PaymentIntent does not exist, so the listing comes back empty and this check --
whose entire purpose is "has a refund already gone out?" -- silently reports
"nothing reached Stripe" for a refund that did.

Act on what comes back:

| Result | Action |
|---|---|
| A `succeeded` Refund for the owed amount | The debt is paid. Settle the row (step 4). Do not re-issue. |
| A `pending` Refund | Leave it alone. Connect refunds can sit pending; re-issuing duplicates it. Re-check later. |
| A `failed` Refund | See the warning below. Do **not** re-issue blindly and do **not** change the status. |
| An empty list | Nothing reached Stripe. Only this case justifies issuing the refund. |

#### Step 3: Issue the refund, under the stable key

The key names one increment:

`refund:capacity:<payment_id>:<seq>` -- where `<seq>` is the increment's own
`seq` from `refund_increments`.

The key names the increment it pays for, so it never moves when new debt
arrives, and a genuinely new increment can never be folded into one already
sent. Retrying a failed attempt under the same key is safe and correct; that is
the whole point of it.

```bash
curl -s https://api.stripe.com/v1/refunds \
  -u "$STRIPE_SECRET_KEY:" \
  -H "Idempotency-Key: refund:capacity:<payment_id>:<seq>" \
  -d payment_intent=<stripe_payment_intent_id> \
  -d amount=<this increment's cents, NOT refund_owed_cents> \
  -d reason=requested_by_customer \
  -d reverse_transfer=true \
  -d refund_application_fee=<true|false>
```

`reason` is not optional here. The automated path always sends
`requested_by_customer`, and Stripe rejects a replay of a used idempotency key
whose parameters differ rather than folding it — so a hand-issued refund that
omits it cannot share a key with the automated attempt, and whichever runs
second is refused.

**One refund per unsettled increment.** Repeat this call for each element of
`refund_increments` whose `settled_at` is null, using that element's `seq` in
the key and that element's `cents` as the amount. Sending `refund_owed_cents`
under a single key is the shape that caused a double refund: the key moved as
the debt grew, so Stripe saw a key it had never seen and paid the whole
accumulated balance again.

`refund_application_fee` and `reverse_transfer` are destination-charge
parameters. The automated refund sends neither, so the platform keeps its fee
-- see **Refund policy** above.

> **Stripe prunes idempotency keys after 24 hours.** The key protects a retry
> made minutes later. It does **not** protect one made the next day: the same
> key sent after 24 hours is a brand new request and a second refund. Past that
> window, step 2's listing is the only thing standing between you and paying
> twice. List again immediately before sending, every time.

#### Step 4: Settle the row

Clear the obligation and move the status once the refund is confirmed
`succeeded`:

```bash
psql $DATABASE_URL -c \
  "UPDATE \"<sacp-slug>\".payments
      SET refund_owed_cents = GREATEST(0, refund_owed_cents - COALESCE((
              SELECT (e->>'cents')::int FROM jsonb_array_elements(refund_increments) e
               WHERE (e->>'seq')::int = <seq> AND e->>'settled_at' IS NULL), 0)),
          refunded_cents    = LEAST(amount_cents, refunded_cents + COALESCE((
              SELECT (e->>'cents')::int FROM jsonb_array_elements(refund_increments) e
               WHERE (e->>'seq')::int = <seq> AND e->>'settled_at' IS NULL), 0)),
          refund_increments = COALESCE((
              SELECT jsonb_agg(
                       CASE WHEN (e->>'seq')::int = <seq>
                              AND e->>'settled_at' IS NULL
                            THEN e || jsonb_build_object('settled_at', to_jsonb(NOW()),
                                                         'refund_id', to_jsonb('<re_...>'::text))
                            ELSE e END ORDER BY (e->>'seq')::int)
                FROM jsonb_array_elements(refund_increments) e), '[]'::jsonb)
    WHERE id = '<payment_id>'"
```

> **The `COALESCE`s are load-bearing, not tidiness.** When the subquery matches
> nothing -- an already-settled `seq`, or a mistyped one -- it returns SQL NULL,
> and Postgres's `GREATEST`/`LEAST` **ignore** NULL rather than propagating it.
> `GREATEST(0, NULL)` is `0` and `LEAST(amount_cents, NULL)` is `amount_cents`,
> so without them re-running this block **zeroes a live debt and records the
> entire cart as refunded**. The row then passes the status move below, leaves
> this queue, and can never be refunded again because
> `amount_cents > refund_owed_cents + refunded_cents` is false forever.
> `jsonb_agg` over zero rows is likewise NULL against a NOT NULL column.

The amount is derived from the increment rather than typed in, and every clause
is guarded on `settled_at IS NULL`.

**One increment per `seq`.** These scalar subselects raise `more than one row
returned by a subquery used as an expression` if two unsettled increments share
a seq -- and Step 5's append block is the only thing that can create that, since
the code always derives `seq` from `refund_seq + 1`. The code's own copy uses
`SUM(...) ... HAVING COUNT(*) > 0` and survives it; this one does not, and it
fails *after* Step 3 has already paid Stripe. Append with `refund_seq + 1`,
never a literal. Both matter: the code's copy
(`settle_refund_increment`) has the same guards and is idempotent because of
them. Without them, re-running this block double-counts the money returned, and
a mistyped `<seq>` moves the balance while leaving the increment still due — the
row's own one-row check passes in both cases.

Per increment, subtracting rather than clearing -- a debt that grew while the
refund was in flight must not be erased along with the part that was paid. Then
move the status **only once `refund_owed_cents` is zero and no
`refund_manual_review` remains**:

```bash
psql $DATABASE_URL -c \
  "UPDATE \"<sacp-slug>\".payments
      SET status = CASE WHEN refunded_cents >= amount_cents
                        THEN 'refunded' ELSE 'partially_refunded' END
    WHERE id = '<payment_id>' AND status = 'refund_pending'
      AND refund_owed_cents = 0
      AND COALESCE(jsonb_array_length(metadata->'refund_manual_review'), 0) = 0"
```

The status is **derived, not typed**. Writing the literal `refunded` here is
wrong in the common case: this block's own `refund_owed_cents = 0` guard is
satisfied precisely when a partial discharge completes, so a hand-written
`refunded` would claim a full return of a cart that got part of one. That is
the ledger distinction Leg 3 reads. This is the same rule the automatic path
applies (`Registry::DAO::Payment::_apply_refund_result`): the full cart is
`refunded`, anything short of it is `partially_refunded`.

Check what the UPDATE reported, and read zero correctly -- it usually is not
concurrency:

| Reported | Means |
|---|---|
| 1 | the row moved |
| 0, and `refund_owed_cents > 0` | **the ordinary case**: increments remain. Go back to Step 3 for the next one. |
| 0, and `metadata.refund_manual_review` is set | the flag guard. Resolve it via Step 5. |
| 0, and neither of those | something else moved the status. Re-read the row before doing anything more. |

#### Step 5: Resolve a manual-review flag

A row with `refund_manual_review` set stays `refund_pending` even when
`refund_owed_cents` is zero and every increment is settled. That is deliberate
-- it is the only thing keeping the row in Step 1's results until a human has
decided about the share the code could not compute -- but it means **the row has
no exit until you provide one.** Nothing in the code clears this flag.

Work out what is actually owed for each entry in the array. If money is owed,
record it as a normal debt and settle it through Steps 2-4:

```bash
psql $DATABASE_URL -c \
  "UPDATE \"<sacp-slug>\".payments
      SET status            = 'refund_pending',
          refund_seq        = refund_seq + 1,
          refund_owed_cents = refund_owed_cents + <cents>,
          refund_increments = refund_increments || jsonb_build_object(
              'seq', refund_seq + 1, 'cents', <cents>,
              'children', '[\"<child_id>\"]'::jsonb, 'settled_at', NULL)
    WHERE id = '<payment_id>'
      AND amount_cents > refund_owed_cents + refunded_cents"
```

> **`status = 'refund_pending'` is not optional.** `record_capacity_obligation`
> sets it unconditionally, and everything downstream depends on it: Step 4's
> settle and status statements are both guarded on `status = 'refund_pending'`,
> and `_refundable_status` is `completed|refund_pending`, so a debt recorded on
> a row left `refunded` or `partially_refunded` is **invisible to every
> automated retry** — the webhook redelivery and the parent-return path both
> die inside their always-2xx catch, silently, forever. You would also finish
> with `refunded_cents = amount_cents` under a `partially_refunded` status,
> which is the ledger distinction Leg 3 reads, inverted.
>
> This matters because the row it applies to is one the code itself produces:
> `flag_refund_manual_review` writes the flag on a terminal row deliberately,
> and Step 1's second predicate exists to surface exactly that.

The predicate is the code's headroom rule (`>`, on the sum of what is owed and
what has already gone back). If it matches no rows the cart has nothing left and
the discrepancy needs escalating rather than forcing. Unlike the code, this does
**not** clamp `<cents>` to the remaining headroom -- check
`amount_cents - refund_owed_cents - refunded_cents` yourself before running it,
or you will trip `payments_refund_total_check`, which constrains
`refund_owed_cents + refunded_cents` against the charge -- the per-column
bounds do not, and an earlier version of this note named one of them.

Enter **integer cents**. `payments_refund_increments_cents_integer` refuses a
decimal outright, so this is now an error at entry rather than a row that breaks
later -- before that constraint existed, the column rounded 130.50 to 131 while
the increment kept 130.50, and every subsequent `(e->>'cents')::int` threw on
that row forever, including one inside the settlement transaction.

Then, once nothing is owed, clear the flag and let the status move:

```bash
psql $DATABASE_URL -c \
  "UPDATE \"<sacp-slug>\".payments
      SET metadata = metadata - 'refund_manual_review'
    WHERE id = '<payment_id>' AND refund_owed_cents = 0"
```

Record the decision on the ticket before removing the flag -- once it is gone
nothing else remembers a human looked at it.

**Then go back and run Step 4's status statement.** Clearing the flag does not
move the status; nothing in the code does either, because
`settle_refund_increment` deliberately refuses to move a row while a flag is
set, and by the time you clear it there are no increments left to settle. A row
left here sits in Step 1's results forever with nothing owed and nothing to do.

If the recording statement reports zero rows, check the status before assuming
a mistake. `flag_refund_manual_review` deliberately leaves a terminal row
terminal -- the preamble above says so -- and the recording statement's headroom
predicate will also refuse a cart with nothing left. Neither is operator error.
A row that is already `refunded` with its flag cleared and nothing owed is
finished; leave it.

#### A failed refund is NOT `refund_failed`

Never write `refund_failed`, or any status outside the seven the code knows:
`pending`, `processing`, `completed`, `failed`, `refund_pending`, `refunded`,
`partially_refunded`. As of the `payments-typed-obligation` migration the
database enforces this with a CHECK constraint, so an invented status is now
rejected outright rather than silently accepted.
The string appears nowhere in `lib/`, and it is in none of the three
classifiers that read this column:

| Classifier | Statuses | What it decides |
|---|---|---|
| `_money_has_moved` | `completed`, `refunded`, `partially_refunded`, `refund_pending` | whether a delivery may re-complete the row |
| `_refundable_status` | `completed`, `refund_pending` | whether a refund may be issued at all |
| `_money_returned` | `refunded`, `partially_refunded` | whether any further seat may be granted |

Writing an unknown status does two bad things at once: the row is locked out
of every future refund, *and* the next Stripe redelivery sees an unsettled
payment and re-completes it.

Leave a failed refund as `refund_pending` with the obligation intact, and
record the failure **outside** the status column -- on the ticket, not on the
row. The status column is load-bearing for three classifiers; a note is not.

> **Step 4 has a consequence worth knowing.** Setting a row to `refunded` or
> `partially_refunded` puts it in `_money_returned`, which permanently stops
> `finalize_enrollment` from granting any further seat on that payment --
> silently, because both callers discard its return value. That is the intended
> behaviour for a cart whose money went back, and it is why step 4 comes only
> after a `succeeded` refund is confirmed. Do not use those statuses to park a
> row you are still working on; leave it `refund_pending`.

### Charge idempotency

Every payment row carries `metadata.idempotency_token`, a UUID seeded by
`gen_random_uuid()` inside `Registry::DAO::Payment->create`. Intent creation
sends this token to Stripe as the `Idempotency-Key: pi-create:<token>` header.

Behavior by scenario:

- Repeated agreeTerms submit: the workflow step reuses the existing payment row
  (same token, same Stripe key). Stripe deduplicates and returns the original
  PaymentIntent. At most one charge is created for a given submission sequence.
- Retry after a decline: `rotate_idempotency_token` replaces the token with a
  fresh UUID and persists it before creating the new intent. The fresh key
  guarantees a genuinely new charge on the next attempt.

---

## 7. Pre-launch Stripe test suite

A gated suite exercises the real Stripe Connect API against a `sk_test_`
key. It lives under `t/stripe-live/` and proves the direct-charge model, where
every tenant payment is made on the tenant's own connected account:

- `paid-enrollment.t` -- a paid enrollment is a direct charge on the tenant
  account (retrieved with `Stripe-Account`), with no `transfer_data` or
  `on_behalf_of`, carrying the plan's `application_fee_amount`; the charge is
  not on the platform account; `payment_intent.succeeded` settles once through
  the Connect endpoint (`/webhooks/stripe/connect`); a full or partial refund
  is made on the tenant account and leaves `application_fee.amount_refunded`
  at 0; the same idempotency key returns the same intent; plus the unready
  gate, a declined card, and the browser return.
- `instalment-schedule.t` -- the schedule for instalments two onwards is on
  the tenant account with the fee percent and no transfer destination, and is
  not found on the platform account.
- `helpers.t` -- the test helpers confirm and poll on the connected account,
  and an `sk_live_` key makes the suite refuse to run without sending a
  request.
- `connect-helper.t`, `connect-onboarding.t` -- test connected accounts and
  the onboarding flow.
- `platform-account-header.t`, `schedule-fee-precision.t`,
  `service-version.t` -- pinned Stripe behaviours the money path relies on.

Creating connected accounts needs a key with Connect write access; a
restricted key without it stops at `POST /accounts`.

To run:

```bash
STRIPE_SECRET_KEY=<sk_test_...> carton exec prove -lr t/stripe-live/
```

The suite skips cleanly when `STRIPE_SECRET_KEY` is unset or absent.
`Test::Registry::StripeConnect::available()` checks that the key matches
`^sk_test_`, and every network helper calls the same guard before making a
request -- a live key aborts rather than falls through.

Run this suite once in test mode before switching SACP from test to live keys
(see step 5).
