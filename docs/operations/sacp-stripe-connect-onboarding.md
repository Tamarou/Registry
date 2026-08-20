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
  "SELECT id, amount_cents, metadata->>'refund_owed_cents' AS owed_cents,
          metadata->>'refund_owed_children' AS owed_children,
          stripe_payment_intent_id, completed_at
     FROM \"<sacp-slug>\".payments
    WHERE status = 'refund_pending'
    ORDER BY completed_at"
```

`refund_owed_cents` is the amount owed; `refund_owed_children` is the child id
list that also forms the idempotency key. A row with `refund_manual_review` set
in its metadata reached a state the automatic path could not resolve and needs
a human decision on the amount before anything is sent to Stripe.

#### Step 2: List refunds before issuing one

**Always list first.** The failure that stranded the row may have happened
after Stripe accepted the refund, so the debt can already be discharged:

```bash
curl -s https://api.stripe.com/v1/refunds \
  -u "$STRIPE_SECRET_KEY:" \
  -H "Stripe-Account: <tenant-connect-account-id>" \
  -G -d payment_intent=<stripe_payment_intent_id>
```

Act on what comes back:

| Result | Action |
|---|---|
| A `succeeded` Refund for the owed amount | The debt is paid. Settle the row (step 4). Do not re-issue. |
| A `pending` Refund | Leave it alone. Connect refunds can sit pending; re-issuing duplicates it. Re-check later. |
| A `failed` Refund | See the warning below. Do **not** re-issue blindly and do **not** change the status. |
| An empty list | Nothing reached Stripe. Only this case justifies issuing the refund. |

#### Step 3: Issue the refund, under the stable key

The key is derived from the payment id and the owed-children list, sorted:

- Whole payment: `refund:capacity:<payment_id>`
- Per child: `refund:capacity:<payment_id>:<child_id>,<child_id>` (ids sorted)

```bash
curl -s https://api.stripe.com/v1/refunds \
  -u "$STRIPE_SECRET_KEY:" \
  -H "Stripe-Account: <tenant-connect-account-id>" \
  -H "Idempotency-Key: refund:capacity:<payment_id>" \
  -d payment_intent=<stripe_payment_intent_id> \
  -d amount=<refund_owed_cents> \
  -d reverse_transfer=true \
  -d refund_application_fee=<true|false>
```

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
      SET status = 'refunded',
          metadata = (metadata - 'refund_owed_cents'
                               - 'refund_owed_children'
                               - 'refund_manual_review')
    WHERE id = '<payment_id>' AND status = 'refund_pending'"
```

Use `partially_refunded` instead of `refunded` when the amount returned is
less than the row's `amount_cents`. This is the same rule the automatic path
applies (`Registry::DAO::Payment::_apply_refund_result`): the full cart is
`refunded`, anything short of it is `partially_refunded`.

The `status = 'refund_pending'` predicate in the WHERE clause is not
decoration -- check that the UPDATE reported one row. Zero means something else
moved the status while you were working, and you should re-read the row before
doing anything more.

#### A failed refund is NOT `refund_failed`

Never write `refund_failed`, or any status outside the five the code knows.
The string appears nowhere in `lib/`, and it is in neither classifier --
`Registry::DAO::Payment::_money_has_moved`
(`completed|refunded|partially_refunded|refund_pending`) and
`_refundable_status` (`completed|refund_pending`). Writing it does both bad
things at once: the row is locked out of every future refund, *and* the next
Stripe redelivery sees an unsettled payment and re-completes it.

Leave a failed refund as `refund_pending` with the obligation intact, and
record the failure **outside** the status column -- on the ticket, not on the
row. The status column is load-bearing for two classifiers; a note is not.

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
