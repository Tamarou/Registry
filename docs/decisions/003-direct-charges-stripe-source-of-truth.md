# ABOUTME: Architecture Decision Record for charging every sale directly on the seller's own Stripe account.
# ABOUTME: Records why Stripe is the source of truth for money and customers, and what Registry deliberately does not do.

# ADR 003: Direct Charges on the Seller's Account, with Stripe as the Source of Truth

**Status:** Accepted

**Date:** 2026-11-24

---

## Context

Registry first took payments as **destination charges**: the charge was made
on the Connect platform account (Tamarou's) with `transfer_data` naming the
tenant, refunds sent `reverse_transfer`, and the platform's fee was refunded
by default. The August PriceOps spec and the operator runbook
[`sacp-stripe-connect-onboarding.md`](../operations/sacp-stripe-connect-onboarding.md)
were built on that design.

Under destination charges the customer, the payment method, refunds and
disputes all live on the platform account. A tenant cannot see or act on its
own customers in its own Stripe dashboard, and anything the tenant does there
does not reach Registry. Nothing has been sold through Registry yet, so there
were no customers or payment methods to move.

The PriceOps model spec (`docs/superpowers/specs/2026-11-21-priceops-model-design.md`,
on the `docs/priceops-model-design` branch; sections "Decided with perigrin",
"Rules that hold" and step 2 of "Order of work") records perigrin's decision
to reverse this. Step 2 of the `priceops-day-one` chain implemented it. This
ADR records the result so the next reader does not rebuild destination
charges.

---

## Decision

### Every sale is a direct charge on the seller's own account

Each tenant connects a **Standard** account
(`Registry::Controller::StripeConnect`, `ACCOUNT_TYPE => 'standard'`). Every
sale is charged on the selling tenant's own account, so the customer, payment
method, refunds and disputes live there. The tenant is the merchant of record.
No `transfer_data` and no `on_behalf_of` are sent.

How the code does it:

- `Registry::Service::Stripe->for_account($acct)` returns a client that sends
  a `Stripe-Account` header on every request. It refuses an id that is not
  `acct_` followed by word characters, so `undef`, `''` or a value with CR/LF
  never yields a client acting on the platform account.
- `Registry::DAO::Payment->create` snapshots the seller's
  `stripe_connect_account_id` from `registry.tenants` into the payment's
  metadata, ignoring any caller-supplied value. Every intent, retry, retrieve,
  cancel and refund for that payment goes to the account it was first charged
  on, even if the tenant's account changes later.
- `Payment->stripe_client` binds to that snapshot and never falls back to an
  unbound client; a payment with no seller account dies before calling Stripe.
- The Stripe customer, the Payment Element in the browser, and instalment
  subscription schedules are all on the seller's account. Schedules send no
  `transfer_data`.

### The platform's share is `application_fee_amount`, omitted when zero

The platform's share is the charge's `application_fee_amount`. It is computed
once, when the payment is created, in integer cents, rounding an exact half to
even (ADR 005, ruling 7c; `Payment::application_fee_cents`). The rate and the
plan version that priced it are snapshotted with the payment, so retries under
the same Idempotency-Key send the same fee and the recorded fee names the
right plan.

A fee of zero is **omitted**, never sent as `application_fee_amount=0`
(`Payment::_connect_params`). `record_platform_fee` records an omitted fee on
a connected payment as 0, because Stripe reports none.

Instalment schedules send `default_settings[application_fee_percent]`
instead, and only when the percent is above zero; Stripe computes each
instalment's fee from it. The fee on each paid instalment invoice is then
recorded from the invoice.

Today the rate comes from `registry.tenants.platform_pricing_plan_id`, falling
back to the 0% Free plan (`Registry::PriceOps::RevenueShare`). The platform
tenant's own sales therefore take no fee through the same "omit at zero" rule,
not through a platform check. Step 3 moves the rate source to the tenant's
entitlement from the platform.

### Refunds send no `reverse_transfer`, and the fee is kept

`Payment->refund_async` refunds on the seller's account with only
`payment_intent`, `amount` and `reason`. It sends neither `reverse_transfer`
(there is no transfer to reverse) nor `refund_application_fee`, so Stripe's
default applies and **Tamarou keeps its fee on a refund**. The old resolver
that read `refund_application_fee` from plan configuration is gone.

A refund Stripe answers `pending` (or `requires_action`) is held, not counted,
and settled later from `refund.updated` on the Connect endpoint. A `failed` or
`canceled` refund is recorded and reported as a failure.

The exception is an explicit call. `Payment->refund_platform_fee_async` reads
the charge's fee id through the seller-bound client, then refunds the fee on
the platform's own account (the fee object lives there, so the
application-fee calls in `Service::Stripe` never send `Stripe-Account`). It
writes nothing itself; what was returned is recorded from
`application_fee.refunded`.

### Every payment event arrives at the Connect endpoint

`POST /webhooks/stripe/connect` (`Webhooks->stripe_connect`) verifies against
its own secret, `STRIPE_CONNECT_WEBHOOK_SECRET`, so a delivery signed for the
platform endpoint never verifies there. Production startup names the variable
when it is missing.

- **Tenant by `event.account`.** The tenant is found by an exact match of the
  top-level `account` against `registry.tenants.stripe_connect_account_id`,
  never from metadata. If metadata names a different tenant, the account wins
  and a warning is logged.
- **Only the intent Registry stored settles.** `payment_intent.succeeded`
  settles a payment only when the intent id equals the one Registry stored.
  The seller owns the account and could mint an intent carrying our
  `payment_id`; metadata proves nothing.
- **Instalment invoices** are matched by the schedule behind the invoice's
  subscription (read from Stripe with `expand[]=schedule`, because an invoice
  names only its subscription under API `2024-12-18.acacia`), and only for
  billing reasons the schedule produces.
- **`account.updated`** mirrors the tenant's readiness flags.

The platform endpoint, `POST /webhooks/stripe` with `STRIPE_WEBHOOK_SECRET`,
keeps events on the platform's own account: tenant billing, and
`application_fee.refunded`, which it records against the tenant named by the
fee's `account`.

### Stripe is the source of truth for money and customers

Registry follows Stripe and never re-charges to undo what happened there.

- An event for a payment Registry did not make (a studio's own Terminal or
  counter sale) is answered 200, logged and ignored.
- Refund, dispute and customer events (`STRIPE_MOVES` in `Webhooks.pm`) are
  verified and **stored, not applied**: `registry.webhook_events` keeps the
  account, tenant and payload, unprocessed. One from an unknown account is
  stored with no tenant rather than lost. Applying them to entitlements is
  step 5.
- Any other event for an unknown account is answered 200 and not claimed.

### The platform's own account needs no special case

The platform tenant (`registry`) sells like any seller: its row names
Tamarou's account, and `for_account` binds to it.

The spec left open whether Stripe accepts a `Stripe-Account` header naming
the API key's own (platform) account. The test-mode check in
[`t/stripe-live/platform-account-header.t`](../../t/stripe-live/platform-account-header.t)
found, on 2026-11-23 against Stripe API `2024-12-18.acacia`, that it is
**accepted** for creating and confirming a payment intent, creating a
customer, and retrieving the intent. The intent is retrievable without the
header, so it is on the platform account. A header naming a nonexistent
account is refused with `account_invalid`, so the header is checked, not
ignored.

The rule that follows: **send the header for every seller, the platform
included.** The planned fallback (omit the header when the seller's account
equals the API key's own account, a comparison of two data values rather than
a platform check) was built only if Stripe refused the header. It did not, so
that issue was cancelled. If Stripe ever starts refusing the header, the live
test fails, and that fallback is the fix.

---

## Consequences

### What Registry deliberately does not do

- **No destination charges.** No `transfer_data`, no `on_behalf_of`, on
  intents or on schedules.
- **No `reverse_transfer`** on any refund.
- **No fee refund by default.** The fee is returned only through
  `refund_platform_fee_async`, the admin exception. No screen calls it yet;
  letting the platform tenant's admin apply Solo's fee-refund exception is
  step 5.
- **No `application_fee_amount` of zero** is ever put in a request.
- **No applying seller-made moves yet.** Refunds, disputes and customer
  changes made in a tenant's dashboard are stored, not applied, until step 5.
- **No re-charging** to contradict Stripe.

### One-way doors and costs

- **Dispute fees fall on the tenant**, as merchant of record, where Stripe
  puts them.
- **Tenants connect Standard accounts through the v1 Accounts API**
  (`Service::Stripe->create_account_async`, `POST /v1/accounts`). If that
  moves to Accounts v2, the settings chosen there are one-way doors.
- A tenant's customers and payment methods live on its account. Moving a sale
  between accounts is not possible after the fact, which is why the seller
  account is snapshotted at payment creation.
- The seller can edit metadata on its own account, so no Connect handler
  trusts metadata to choose a tenant, a payment or an instalment row; seller
  values are escaped before they reach the log.

### Known gaps

- The Connect handler reads only the top-level `invoice.subscription`, the
  `2024-12-18.acacia` spelling. A move of the Connect endpoint's API version
  needs that read updated (marked `shortcut:` in `Webhooks.pm`).
- A `refund.updated` that arrives before Registry has recorded its own refund
  as pending is stored unapplied, and `charge.refund.updated` is never
  matched (also marked `shortcut:`).
- The operator runbook still describes destination charges; its rewrite is a
  separate step-2 documentation issue.

---

## Alternatives Considered

### Keep destination charges

Simpler for the platform (one account holds everything) and already built.
Rejected: the tenant would not own its customers, could not refund or answer a
dispute in its own dashboard, and anything it did there would be invisible to
Registry. Changing later would mean moving live customers and payment methods,
which Stripe does not do for you; with no sales yet, now was the cheapest time.

### Destination charges with `on_behalf_of`

Makes the tenant the settlement merchant, but the customer and payment method
still live on the platform account. It does not give the tenant its customers,
which was the point.

### Refund the fee by default

The previous behaviour. Rejected by perigrin: Tamarou keeps its share unless
Tamarou caused the sale to be wrong, as a term of the platform's offer to the
tenant. The exception is an explicit call, not a flag on every refund.

### Choose the tenant from event metadata

Rejected: on a direct charge the seller writes the metadata. `event.account`
is set by Stripe and cannot be forged by the seller.

### Omit `Stripe-Account` for the platform's own account

Planned as a fallback and not built, because Stripe accepts the header (see
above). Sending it for every seller keeps one code path.

---

## References

- Spec: `docs/superpowers/specs/2026-11-21-priceops-model-design.md` (branch
  `docs/priceops-model-design`)
- Rulings: [ADR 005](005-priceops-day-one-rulings.md) (7c half-even rounding,
  8a capped refunds, 13 Stripe test key); [ADR 004](004-step-6-workflow-reach-and-storefront.md)
- Code: [`lib/Registry/Service/Stripe.pm`](../../lib/Registry/Service/Stripe.pm),
  [`lib/Registry/DAO/Payment.pm`](../../lib/Registry/DAO/Payment.pm),
  [`lib/Registry/Controller/Webhooks.pm`](../../lib/Registry/Controller/Webhooks.pm),
  [`lib/Registry/PriceOps/RevenueShare.pm`](../../lib/Registry/PriceOps/RevenueShare.pm)
- Tests: `t/dao/application-fee-omitted-at-zero.t`,
  `t/dao/payment-intent-destination-charge.t` (despite its name, it pins
  direct charges), `t/dao/payment-refund-platform-fee.t`,
  `t/controller/connect-webhook-endpoint.t`,
  `t/controller/connect-webhook-intent-ownership.t`,
  `t/controller/connect-webhook-stores-stripe-moves.t`,
  `t/controller/application-fee-refunded-webhook.t`, and the live suite in
  `t/stripe-live/`
- Runbook: [`docs/operations/sacp-stripe-connect-onboarding.md`](../operations/sacp-stripe-connect-onboarding.md)
