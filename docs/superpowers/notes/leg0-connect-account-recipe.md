# Leg 0: Stripe Test Connected-Account Recipe (validated spike)

Validated 2026-07-03 against Stripe test mode (platform `acct_1NBjkkLMFKfcYAvR`,
API responses recorded live). Full lifecycle proven: create → `charges_enabled`
→ destination charge with application fee → idempotent replay → refund with
transfer reversal + fee return → delete.

This is the recipe `Test::Registry::StripeConnect` (Leg C1) implements. Every
number below is from the actual spike run, not documentation.

## Prerequisites

- `STRIPE_SECRET_KEY` **must** start `sk_test_`. Enforce with a hard guard
  before any call — a live key must abort the suite, never fall through.
- The Stripe MCP server is **not** usable for this: its write surface excludes
  `PostAccounts` and `PostPaymentIntents` (verified 2026-07-03). Suites must
  hit the raw REST API, exactly as `Registry::Service::Stripe` does.

## 1. Create the account (one POST, no onboarding flow)

`POST /v1/accounts` with `type=custom` — Custom is required because it is the
only type where `tos_acceptance` can be set via API, which is what removes the
human onboarding step.

```
type=custom
country=US
email=<anything>@tamarou.com
business_type=individual
capabilities[card_payments][requested]=true   # required for on_behalf_of
capabilities[transfers][requested]=true       # required for transfer_data[destination]
business_profile[mcc]=8299                    # educational services
business_profile[url]=https://tamarou.com
individual[first_name]=Jenny
individual[last_name]=Rosen
individual[email]=<same as email>
individual[phone]=0000000000                  # magic: passes phone validation
individual[dob][day]=1
individual[dob][month]=1
individual[dob][year]=1901                    # magic: passes identity verification
individual[ssn_last_4]=0000                   # magic
individual[id_number]=000000000               # magic: full SSN, passes verification
individual[address][line1]=address_full_match # magic: passes address verification
individual[address][city]=South San Francisco
individual[address][state]=CA
individual[address][postal_code]=94080
individual[address][country]=US
tos_acceptance[date]=<unix now>
tos_acceptance[ip]=8.8.8.8                    # any syntactically valid IP works in test mode
external_account=btok_us_verified             # magic token: pre-verified test bank account
metadata[purpose]=<suite marker for cleanup>
```

Immediately after creation the account looks like:

```json
{ "charges_enabled": false,
  "capabilities": { "card_payments": "pending", "transfers": "active" },
  "requirements": { "currently_due": [], "disabled_reason": "requirements.pending_verification" } }
```

`transfers` is active instantly; `card_payments` sits in simulated identity
verification. `currently_due` is empty — nothing more to submit, just wait.

## 2. Poll until charges_enabled (NOT instant)

`GET /v1/accounts/{id}` until `charges_enabled == true`.

**Measured: 48 seconds** (18 polls at ~2.5s intervals) for `card_payments` to
flip `pending → active`, which flips `charges_enabled` and `payouts_enabled`
together. The C1 helper must poll with a **90-second timeout** and a clear
failure message; an assume-instant design will flake.

## 3. Destination charge (the money-path primitive)

`POST /v1/payment_intents` — mirrors `Registry::DAO::Payment::_connect_params`:

```
amount=1000
currency=usd
payment_method_types[]=card
payment_method=pm_card_visa
confirm=true
transfer_data[destination]={acct}
on_behalf_of={acct}
application_fee_amount=20        # 2% of $10.00 — the live plan rate
```

Result: `status=succeeded`, and the charge carries the full Connect anatomy —
`application_fee` (fee_…) and `transfer` (tr_…) to the destination account.
`on_behalf_of` works because `card_payments` is active (step 2); destination
transfer works because `transfers` is active.

## 4. Idempotency replay (Leg B premise, verified)

Re-POSTing the identical body with the identical `Idempotency-Key` header
returned the **same** PaymentIntent id — no second charge. Stripe's
idempotency layer behaves exactly as Leg B assumes: key + body → cached
response.

## 5. Refund with plan policy (Leg A premise, verified)

`POST /v1/refunds`:

```
payment_intent={pi}
reverse_transfer=true            # pulls the $10 back from the connected account
refund_application_fee=true      # platform returns its $0.20 fee
```

Result: refund `succeeded` with a `transfer_reversal` (trr_…), and the
application fee object shows `amount_refunded == amount`, `refunded: true`.
Both flags do exactly what the refund-as-plan-config design (A1/A2) needs.

## 6. Teardown

`DELETE /v1/accounts/{id}` → `{ "deleted": true }`. Works once the balance is
reversed to zero. C1's cleanup should delete spike accounts by the
`metadata[purpose]` marker; orphans are harmless test-mode noise but delete
anyway.

## Gotchas learned

- **The ~48s verification delay is the whole reason C1 exists as a shared
  helper**: create the account once per suite run (or cache one per CI job),
  not once per test.
- `charges_enabled` requires **both** capabilities: `card_payments` gates
  `on_behalf_of`, `transfers` gates `transfer_data[destination]`. Requesting
  only `transfers` gives an account that can receive transfers but cannot be
  the settlement merchant.
- `tos_acceptance` via API is a Custom-type-only feature — Standard/Express
  test accounts cannot skip onboarding this way.
- The negative test-mode platform balance (from old test refunds) does not
  interfere with any of this.
