# SACP Stripe Connect Onboarding

Operator runbook for wiring SACP's Stripe Standard connected account into the
Registry platform so tenant-scoped destination charges work.

This runbook covers one tenant. Repeat for any future tenant that needs paid
enrollment.

---

## 1. Create / locate SACP's Standard connected account in the Stripe dashboard

1. Log in to the Registry **platform** Stripe account (`acct_1NBjkkLMFKfcYAvR`).
2. Navigate to **Connect → Accounts**.
3. Create a new Standard connected account for SACP, or locate the existing one
   if already created during earlier onboarding.
4. Complete onboarding until the account detail page shows both:
   - `charges_enabled: true`
   - `details_submitted: true`

   These fields appear on the account overview page. If the account shows
   "Restricted" or is missing either flag, the operator or SACP must complete
   the Stripe identity / bank-account verification steps before proceeding.

---

## 2. Record the connected account on the tenant row

Once both readiness flags are true in Stripe, record the account ID in the
Registry database. Replace `acct_XXXX` with SACP's actual account ID and
`<sacp-slug>` with the value in `registry.tenants.slug` for SACP. Find the
slug first if unsure:

```sql
SELECT slug, name FROM registry.tenants WHERE name ILIKE '%sacp%';
```

```sql
UPDATE registry.tenants
SET stripe_connect_account_id = 'acct_XXXX',
    stripe_charges_enabled    = true,
    stripe_details_submitted  = true
WHERE slug = '<sacp-slug>';
```

Verify one row was updated:

```sql
SELECT slug, stripe_connect_account_id, stripe_charges_enabled, stripe_details_submitted
FROM registry.tenants
WHERE slug = '<sacp-slug>';
```

The boolean columns self-heal after this point via the `account.updated` webhook
(see step 3), so manual re-edits are only needed when the webhook is not yet
configured or after a Stripe account suspension.

---

## 3. Webhook configuration

The Registry platform webhook endpoint must receive **both** platform events and
Connect events from connected accounts.

1. In the Stripe dashboard, navigate to **Developers → Webhooks** on the
   platform account (`acct_1NBjkkLMFKfcYAvR`).
2. Edit the existing Registry endpoint.
3. Under **Listen to**, confirm "Events on Connected accounts" is enabled in
   addition to the existing platform events.
4. Ensure `account.updated` is in the event list. This event arrives when a
   connected account's `charges_enabled` or `details_submitted` changes, and
   the `_process_account_updated` handler (`lib/Registry/Controller/Webhooks.pm`)
   mirrors those flags back onto `registry.tenants` automatically.

**`payment_intent.succeeded` routing note:** For destination charges, Stripe
delivers the `payment_intent.succeeded` event to the **platform** webhook, not
the connected account's webhook, and the payment intent metadata fields
(`metadata.payment_id`, `metadata.tenant_slug`) are preserved. Confirm this
once in test mode (step 5) before going live.

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

Use Stripe **test** keys and a Stripe test connected account for this step.
Do not use live keys. Set the environment for the app under test:

```bash
export STRIPE_SECRET_KEY=sk_test_...      # test secret key
export STRIPE_WEBHOOK_SECRET=whsec_...    # the test endpoint's signing secret
```

Note: the application refuses an `sk_live_` key unless `MOJO_MODE=production`
(a safety guard in `Registry::DAO::Payment`), so a test run with a live key
aborts by design.

1. Configure a test tenant with `stripe_connect_account_id` set to a Stripe
   test connected account ID (e.g. `acct_test_XXXX`).
2. Complete one end-to-end paid enrollment through the application for that
   test tenant using Stripe test card `4242 4242 4242 4242`.
3. In the Stripe dashboard (test mode), confirm the resulting charge shows:
   - `transfer_data.destination` set to the test connected account
   - `application_fee_amount` equal to the tenant's plan rate (2% at launch)
     of the charge amount (rounded to the nearest cent, half-up)
   - `on_behalf_of` set to the same connected account
4. Confirm the `payment_intent.succeeded` event arrived on the platform webhook
   (not the connected account's webhook).
5. In the Registry database, confirm:
   - The payment row exists in `<test-tenant-slug>.payments` (tenant schema)
   - The enrollment row exists in `<test-tenant-slug>.enrollments`
   - `registry.payments` has no corresponding row for this payment

Once all five checks pass, the feature is validated and SACP can be switched
from test to live keys.

---

## 6. Platform rate and refund behavior

### Revenue share rate

The application fee charged on each destination charge is calculated from the
tenant's linked pricing plan. The relevant field is
`pricing_configuration->>'percentage'` on the `registry.pricing_plans` row
linked to the tenant via `platform_pricing_plan_id`. The platform free plan
(scope `platform`, `metadata->>'default'='true'`) is the fallback when no plan
is linked. At launch the single percentage plan carries a 2% rate.

Rate resolution is performed by
`Registry::PriceOps::RevenueShare::revenue_share_fraction_for_tenant`, which
returns the fraction (e.g. `0.02` for 2%) used by `_connect_params` to compute
`application_fee_amount` in integer cents, rounded half-up.

### Refund policy config

Whether the platform returns its application fee when a tenant payment is
refunded is controlled by `pricing_configuration.refund_application_fee` on
the tenant's linked pricing plan. This is a JSON boolean stored in the plan's
`pricing_configuration` jsonb column; the default is `true` (the platform
refunds its fee). The `reverse_transfer` flag is always sent for
destination-charge refunds regardless of this setting.

Seeded at deploy time by the `refund-application-fee-config` sqitch change:
both the platform default plan and all tenant percentage plans receive
`refund_application_fee: true` explicitly, making the policy visible even
though an absent or null key also defaults to `true`.

Resolved at refund time by
`Registry::PriceOps::RevenueShare::refund_application_fee_for_tenant($db,
$tenant_slug)`, which returns `1` (refund the fee) or `0` (keep the fee).
`Registry::DAO::Payment::_refund_connect_params` maps those to the string
booleans `'true'`/`'false'` required by Stripe's form-encoded API.

### Clearing a stranded `refund_pending` payment

`refund_pending` means the platform owes a refund it has not yet issued. A
capacity re-check at capture found a child's seat gone, waitlisted them, and
recorded the debt -- and then the refund call itself failed after the
settlement transaction had already committed.

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
          stripe_payment_intent_id, completed_at
     FROM \"<sacp-slug>\".payments
    WHERE status = 'refund_pending'
       OR jsonb_array_length(COALESCE(metadata->'refund_manual_review', '[]'::jsonb)) > 0
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

A row with `refund_manual_review` set reached a state the automatic path could
not resolve -- a child whose share could not be computed -- and needs a human
decision on the amount. Such a row stays `refund_pending` even when
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

`refund_application_fee` follows the tenant's plan config -- see **Refund
policy config** above; `reverse_transfer` is always `true` for
destination-charge refunds.

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

Enter **integer cents**. A decimal is accepted by the column, which rounds it,
but stored verbatim in the increment -- and `(e->>'cents')::int` then throws on
that row forever, taking the settlement path down with it.

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

A gated suite exercises the real Stripe Connect API against a live `sk_test_`
key. It lives under `t/stripe-live/` and currently includes
`connect-helper.t` and `helpers.t`. The paid-enrollment end-to-end suite lands
as Leg C3.

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
