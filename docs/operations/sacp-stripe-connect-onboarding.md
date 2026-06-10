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
per-tenant payment tables and will abort loudly on two pre-flight conditions:

| Pre-flight | Error trigger | Remediation |
|---|---|---|
| Payer-residency | A registry-resident tenant payment's payer does not exist in the tenant schema | `SELECT copy_user(dest_schema => '<slug>', user_id => '<id>');` for each missing user |
| Schedule guard | `registry.scheduled_payments` rows reference payments tagged to a tenant | Manual investigation required; contact perigrin before proceeding |

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
   - `application_fee_amount` equal to 2.5% of the charge amount (rounded
     to the nearest cent, half-up)
   - `on_behalf_of` set to the same connected account
4. Confirm the `payment_intent.succeeded` event arrived on the platform webhook
   (not the connected account's webhook).
5. In the Registry database, confirm:
   - The payment row exists in `<test-tenant-slug>.payments` (tenant schema)
   - The enrollment row exists in `<test-tenant-slug>.enrollments`
   - `registry.payments` has no corresponding row for this payment

Once all five checks pass, the feature is validated and SACP can be switched
from test to live keys.
