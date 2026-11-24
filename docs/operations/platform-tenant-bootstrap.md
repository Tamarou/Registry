# ABOUTME: Operator runbook for the platform tenant's bootstrap root: the registry row, its Stripe account and first admin.
# ABOUTME: Covers the deployment variables, the pre-deploy checks, running and verifying `registry platform bootstrap`, and the seeded rights and offers.

# Platform Tenant Bootstrap

The bootstrap root is what exists before any workflow can run: the `registry`
tenant row with Tamarou's Stripe account, its first admin, its operator right,
its right to run product design, and the first version of Solo. Two things
build it:

- **The migrations** (`sqitch deploy`), once: they create the row, the seeded
  offers and the platform's entitlements, by fixed id.
- **`./registry platform bootstrap`**, on every start: it writes the three
  `PLATFORM_*` variables onto that row and onto its first admin. A migration
  runs once and cannot read the container's environment, so this command does
  ([ADR 005](../decisions/005-priceops-day-one-rulings.md), ruling 5).

The rulings behind this are in ADR 005 and
[ADR 004](../decisions/004-step-6-workflow-reach-and-storefront.md). The variable
list for Render is in [DEPLOYMENT.md](../../DEPLOYMENT.md#2-environment-variables).

Placeholders below: `acct_XXXX` is Tamarou's Stripe account id and
`admin@example.com` is the platform admin's address. Run SQL in `psql` against
the production database (from the Render shell of `registry-app`:
`psql "$DB_URL"`).

---

## 1. The platform tenant is `registry`

The platform is one row in `registry.tenants`:

| Column | Value |
|---|---|
| `id` | `00000000-0000-0000-0000-000000000000` (the all-zeros id, kept) |
| `slug` | `registry` |
| schema | `registry`: the platform tenant's own schema |

Before this change the platform was two rows: `registry` (a random id, owner of
the `registry` schema) and the all-zeros `registry-platform` (no schema).
`registry-platform` no longer exists. The `collapse-platform-tenant` migration
moved everything that named the old `registry` row (memberships, profile,
domains, pricing relationships, every `*tenant_id` column) onto the all-zeros
row, deleted the old row, and gave the all-zeros row the slug `registry`. Both
spellings, `registry-platform` and `registry_platform`, are now reserved slugs,
so no studio can take them.

Code finds the platform by slug (`Registry::DAO::Tenant->platform`), never by
the literal id.

Verify:

```sql
SELECT id, slug, name FROM registry.tenants
 WHERE slug IN ('registry', 'registry-platform') OR id = '00000000-0000-0000-0000-000000000000';
```

Expect one row: the all-zeros id with slug `registry`.

---

## 2. Before the first deploy that carries this

Run these against production before deploying. Each one is a query the
migrations would otherwise answer by refusing to deploy or by changing access.
The `registry-platform` rows still exist at this point, because the deploy has
not run yet.

1. **Compare `magic_link_expiry_hours` on the two platform rows.**

   ```sql
   SELECT id, slug, magic_link_expiry_hours FROM registry.tenants
    WHERE slug IN ('registry', 'registry-platform');
   ```

   If the two values differ, `collapse-platform-tenant` refuses to deploy and
   names both. Set them equal, to the value that should stand, then deploy.

2. **Check `canonical_domain` on the two platform rows.**

   ```sql
   SELECT id, slug, canonical_domain FROM registry.tenants
    WHERE slug IN ('registry', 'registry-platform');
   ```

   The collapse keeps the all-zeros row's value, or takes the old `registry`
   row's when the all-zeros row has none. After the deploy, a
   `canonical_domain` on the platform row redirects (301) every host that
   resolves to the platform to that domain, including unverified custom
   domains. If the value is not the platform's real domain, clear or correct
   it before deploying.

3. **List platform members who are not admins.**

   ```sql
   SELECT t.slug, u.username, u.user_type, tu.is_primary
     FROM registry.tenant_users tu
     JOIN registry.tenants t ON t.id = tu.tenant_id
     JOIN registry.users u   ON u.id = tu.user_id
    WHERE t.slug IN ('registry', 'registry-platform')
      AND u.user_type <> 'admin';
   ```

   `tenant-users-role` gives each membership the role of its user's
   `user_type`. Platform access and acting as another tenant read that
   membership role, so anyone listed here loses both when this lands.

4. **Look for a Stripe account shared by two tenants, and for Tamarou's account
   on a studio row.**

   ```sql
   SELECT stripe_connect_account_id, array_agg(slug) AS tenants
     FROM registry.tenants
    WHERE stripe_connect_account_id IS NOT NULL
    GROUP BY stripe_connect_account_id
   HAVING count(*) > 1;

   SELECT id, slug FROM registry.tenants WHERE stripe_connect_account_id = 'acct_XXXX';
   ```

   The first must return no rows: a Stripe account belongs to one tenant at
   most, and `tenant-stripe-account-unique` refuses to deploy and names the
   account otherwise. The second must return nothing, or only a platform row:
   the bootstrap cannot write `acct_XXXX` onto `registry` while a studio holds
   it.

5. **Run the non-Solo-link query.**

   ```sql
   SELECT t.slug, p.id, p.plan_name
     FROM registry.tenants t
     JOIN registry.pricing_plans p ON p.id = t.platform_pricing_plan_id
    WHERE t.slug NOT IN ('registry', 'registry-platform')
      AND p.plan_family_id NOT IN (SELECT plan_family_id FROM registry.pricing_plans
                                    WHERE metadata->>'launch_rate' = 'true');
   ```

   Any row stops the deploy at `platform-entitlement-replaces-plan-link`: that
   tenant is linked to a plan outside the Solo family, and no published offer
   matches it. Decide which offer that tenant accepted before deploying.

6. **Check `registry.tenant_resources`, if it exists.**

   ```sql
   SELECT to_regclass('registry.tenant_resources');
   -- only if that is not null:
   SELECT * FROM registry.tenant_resources;
   ```

   `operator-right` creates this table holding one row, the all-zeros tenant
   with `operator`. `operator-right-entitlement` moves that row into an
   entitlement and drops the table, and refuses to deploy if the table holds
   any other row. On a database that has neither change yet, the first query
   returns null and one deploy runs both.

7. **Confirm the deploy can create `btree_gist`.** `priceops-entitlement-one-phase`,
   which `bootstrap-platform-offers` depends on, runs
   `CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public`. That needs CREATE on the
   database, so sqitch must run as the database owner. Check on staging first:

   ```sql
   SELECT pg_get_userbyid(datdba) AS owner, current_user
     FROM pg_database WHERE datname = current_database();
   CREATE EXTENSION IF NOT EXISTS btree_gist;
   ```

   `owner` should equal `current_user` for the role sqitch uses, and the
   `CREATE EXTENSION` should succeed.

---

## 3. The deployment variables

All three are declared in `render.yaml` with `sync: false`, so their values are
set in the Render dashboard. `PLATFORM_STRIPE_ACCOUNT_ID` and
`PLATFORM_STRIPE_READY` are in the `registry-stripe` group;
`PLATFORM_ADMIN_EMAIL` is in `registry-config`.

| Variable | What it sets | Accepted values |
|---|---|---|
| `PLATFORM_STRIPE_ACCOUNT_ID` | `registry.tenants.stripe_connect_account_id` on the `registry` row | `acct_` followed by letters, digits or `_` |
| `PLATFORM_STRIPE_READY` | `stripe_charges_enabled` and `stripe_details_submitted` on that row, both to the same value | `true`/`false`, `1`/`0`, `yes`/`no`, `on`/`off`, any case |
| `PLATFORM_ADMIN_EMAIL` | the email on the platform's first admin's `registry.user_profiles` row; creates that admin if the platform has no admin-role member | one address, at most 255 characters, no whitespace or control characters |

`PLATFORM_STRIPE_ACCOUNT_ID` is Tamarou's own Stripe account, not a connected
account. Set `PLATFORM_STRIPE_READY` to `true` once Stripe has approved it.

**Production refuses to start without them.** If any of the three is missing
or malformed, the command writes nothing and exits non-zero, and
`docker-entrypoint.sh` stops the boot when `MOJO_MODE=production`
(`FATAL: platform bootstrap failed -- refusing to start`). Outside production
the entrypoint prints a warning and carries on.

**Re-running with the same values changes nothing.** When the row already has
the configured account and readiness, it is not rewritten. When the admin's
email already matches, the profile is not written.

**The configuration wins on every start for readiness and the admin email.**
The command re-asserts both each time it runs. A readiness flag changed in the
database, or an email the admin changed on their own profile, is put back to
the configured value at the next deploy. The Stripe account id is the one
exception (see section 6).

---

## 4. What runs on every start

`docker-entrypoint.sh` runs these in order on the web service
(`SERVICE_TYPE=web`), and stops at the first failure:

1. `sqitch deploy`
2. `./registry workflow import registry`
3. `./registry template import registry`
4. `./registry platform bootstrap`

Steps 1 to 3 stop the boot in any mode. Step 4 stops it only in production. The
worker service runs none of them.

The boot log shows the outcome:

```
Bootstrapping the platform tenant...
Platform Stripe account: acct_XXXX (ready)
Platform admin email: admin@example.com
Platform tenant bootstrapped successfully
```

`(not ready)` in place of `(ready)` means `PLATFORM_STRIPE_READY` is false. A
line beginning `WARNING: The platform tenant already records Stripe account`
means the row kept a different account (section 6).

---

## 5. Running the bootstrap by hand

Use this to apply changed variables without waiting for a deploy, or to see why
a boot failed.

1. Open a shell where the variables and `DB_URL` are set: the Render shell of
   `registry-app`, or locally with them exported.

2. Run the command.

   - In the container (working directory `/app`):

     ```bash
     ./registry platform bootstrap
     ```

   - Locally:

     ```bash
     PLATFORM_STRIPE_ACCOUNT_ID=acct_XXXX \
     PLATFORM_STRIPE_READY=true \
     PLATFORM_ADMIN_EMAIL=admin@example.com \
       carton exec ./registry platform bootstrap
     ```

   Verify: it prints `Platform Stripe account: ...` and
   `Platform admin email: ...`, and `echo $?` prints `0`. On a refusal it
   prints the reason, ending `-- the platform tenant and its admin were left as
   they are`, and exits non-zero.

3. Check the row.

   ```sql
   SELECT id, slug, stripe_connect_account_id,
          stripe_charges_enabled, stripe_details_submitted
     FROM registry.tenants WHERE slug = 'registry';
   ```

   Expect `acct_XXXX`, and both flags equal to `PLATFORM_STRIPE_READY`.

4. Check the admin.

   ```sql
   SELECT u.username, up.email, tu.role, tu.is_primary
     FROM registry.tenant_users tu
     JOIN registry.users u ON u.id = tu.user_id
     LEFT JOIN registry.user_profiles up ON up.user_id = tu.user_id
    WHERE tu.tenant_id = '00000000-0000-0000-0000-000000000000'
      AND tu.role = 'admin';
   ```

   Expect a row whose `email` is `PLATFORM_ADMIN_EMAIL`. An admin the bootstrap
   created has `username` equal to the address and `is_primary` true.

5. Sign in as the platform admin. Go to `<BASE_URL>/auth/login`, enter
   `PLATFORM_ADMIN_EMAIL`, and follow the magic link sent to it.

   Verify: the link signs you in, and `/platform/tenants` loads.

6. Open `<BASE_URL>/admin/billing`.

   Verify: with `PLATFORM_STRIPE_READY=true` it shows **You can take
   payments.** With `false` it shows **Stripe still needs something from
   you.** In neither case does its button send you to Stripe: for the platform
   tenant, `POST /admin/billing/connect` redirects back to `/admin/billing`
   and never creates a Stripe account.

---

## 6. What the bootstrap refuses

Every value is checked before anything is written. A refusal exits non-zero
and changes nothing.

| Situation | What happens |
|---|---|
| A variable is unset | `Not set: <names>`; nothing written |
| `PLATFORM_STRIPE_ACCOUNT_ID` is not `acct_...` | refused by name; nothing written |
| `PLATFORM_STRIPE_READY` is not one of the accepted values | refused by name; nothing written |
| `PLATFORM_ADMIN_EMAIL` is not a single address | refused by name, control characters shown escaped; nothing written |
| `PLATFORM_ADMIN_EMAIL` already belongs to another user (compared without case), such as a studio's user | `... is already in use by another user`; nothing written |
| There is no `registry` row | `There is no platform tenant (slug 'registry') to bootstrap; deploy the schema first. No tenant was created.` |

**It never replaces a recorded Stripe account with a different one.** If the
`registry` row already names an account other than
`PLATFORM_STRIPE_ACCOUNT_ID`, the bootstrap keeps that account and its
readiness, prints `WARNING: The platform tenant already records Stripe account
<recorded>; PLATFORM_STRIPE_ACCOUNT_ID is <configured>. Kept <recorded> and its
readiness as they were.`, and exits 0. The boot continues. The admin email is
still applied. To resolve it, set `PLATFORM_STRIPE_ACCOUNT_ID` to the recorded
account, or clear the row's account if the configured one is right:

```sql
UPDATE registry.tenants SET stripe_connect_account_id = NULL
 WHERE slug = 'registry';
```

Then run section 5 again.

**It never creates a second admin.** It targets the platform's admin-role
member, the primary one first. It creates an admin only when the platform has
no admin-role member at all. It never promotes a member who is not an admin,
such as a staff member who is primary.

**It never touches a studio's users.** It writes only the platform admin's
profile, and refuses an address any other user already has.

**A failed first boot can leave a stray user.** Creating the admin and adding
its platform membership are two writes. If a boot fails between them, the next
run refuses the address as already in use. Check for it:

```sql
SELECT u.id, u.username, up.email
  FROM registry.user_profiles up
  JOIN registry.users u ON u.id = up.user_id
 WHERE lower(up.email) = lower('admin@example.com')
   AND NOT EXISTS (SELECT 1 FROM registry.tenant_users tu
                    WHERE tu.user_id = u.id
                      AND tu.tenant_id = '00000000-0000-0000-0000-000000000000');
```

---

## 7. The operator right

The operator right is the resource named `operator`. A tenant that holds it
lets its admins:

- act as another tenant (the `X-As-Tenant` header or the `as-tenant` cookie),
  provided the requested tenant exists;
- use `/platform/jobs`, Minion's job dashboard;
- read `/platform/revenue`, the cross-tenant revenue view.

Two conditions both apply. The tenant must hold the right, and the user must be
a member of that tenant whose membership role is `admin`. `users.user_type` is
never read. Code asks the data (`Registry::DAO::Tenant->holds` and
`admin_of_holder`), never the platform's slug or id, so removing the platform's
holding refuses everyone, platform admins included.

Only `registry` holds it. `operator-right-entitlement` seeds it as the
platform's $0 one-time offer to itself, with the `holder_is_offerer`
condition. `self-offer-guard` adds a trigger on `registry.entitlements` that
refuses any holder of a `holder_is_offerer` version other than the all-zeros
tenant.

| Row | Fixed id |
|---|---|
| resource `operator` | `00000000-0000-0001-0001-000000000001` |
| offer `Platform operator right` | `00000000-0000-0001-0002-000000000001` |
| offer version | `00000000-0000-0001-0003-000000000001` |
| `registry`'s entitlement | `00000000-0000-0001-0004-000000000001` |

Confirm it is held, and by whom:

```sql
SELECT t.slug, e.state, e.in_effect
  FROM registry.entitlements e
  JOIN registry.tenants t        ON t.id = e.holder_tenant_id
  JOIN registry.offer_versions v ON v.id = e.offer_version_id
  JOIN registry.resources r      ON r.id = v.resource_id
 WHERE r.name = 'operator';
```

Expect one row: `registry`, `active`, a range open at the top.

Confirm the guard is installed:

```sql
SELECT tgname FROM pg_trigger
 WHERE tgrelid = 'registry.entitlements'::regclass
   AND tgname = 'entitlement_holder_is_offerer';
```

---

## 8. The right to run product design

`bootstrap-platform-offers` gives the `registry` tenant the right to run its
product-design workflows: one `run:<workflow-slug>` resource for each, each
bought by its own $0 one-time offer from the platform to itself
(`holder_is_offerer`), and held by `registry` from deploy time.

| Resource | Offer version | `registry`'s entitlement |
|---|---|---|
| `run:offer-publishing` | `00000000-0000-0000-0003-000000000011` | `00000000-0000-0000-0004-000000000011` |
| `run:program-creation` | `00000000-0000-0000-0003-000000000012` | `00000000-0000-0000-0004-000000000012` |
| `run:program-setup` | `00000000-0000-0000-0003-000000000013` | `00000000-0000-0000-0004-000000000013` |
| `run:session-creation` | `00000000-0000-0000-0003-000000000014` | `00000000-0000-0000-0004-000000000014` |
| `run:event-creation` | `00000000-0000-0000-0003-000000000015` | `00000000-0000-0000-0004-000000000015` |

Step 6's workflow gate reads these: it admits a workflow the tenant holds an
entitlement to run (ADR 004, ruling b). No code reads them yet.

Confirm they are held:

```sql
SELECT r.name, e.state
  FROM registry.entitlements e
  JOIN registry.offer_versions v ON v.id = e.offer_version_id
  JOIN registry.resources r      ON r.id = v.resource_id
 WHERE e.holder_tenant_id = '00000000-0000-0000-0000-000000000000'
   AND r.name LIKE 'run:%'
 ORDER BY r.name;
```

Expect five `active` rows.

---

## 9. Solo v1 and the platform's 0% offer to itself

`bootstrap-platform-offers` also seeds:

- **Solo v1**, the offer the platform sells to studios: offer version
  `00000000-0000-0000-0003-000000000001`, buying `payment processing`, $0 plus
  2.5% of each sale (payment plan `revenue_share`, fraction `0.025`). Tamarou
  keeps its fee on a refund unless the platform tenant's admin applies the
  exception. `registry` does not hold it.
  `platform-entitlement-replaces-plan-link` gives Solo v1 to every studio
  that was linked to a Solo plan, and drops the old plan link.
- **The platform's payment processing offer to itself**: offer version
  `00000000-0000-0000-0003-000000000002`, payment plan `revenue_share` at an
  explicit fraction of `0`, held by `registry` through entitlement
  `00000000-0000-0000-0004-000000000002`. It carries `holder_is_offerer`, so
  only `registry` may hold it.
- **Email sending** for the platform, at a stated $0 one-time (version
  `...0003-000000000003`, entitlement `...0004-000000000003`).

**Why the platform's own sales send no `application_fee_amount`.** A charge's
fee comes from the selling tenant's platform entitlement to payment processing.
For `registry` that is the 0% self-offer, so the fee is 0 cents, and a zero
application fee is omitted from the Stripe request, never sent as 0. There is no
fallback: a tenant with no entitlement to payment processing in effect cannot
be charged for, so this entitlement must exist for the platform to take
payments.

Confirm:

```sql
SELECT t.slug, o.name, p.kind, p.fraction, e.state
  FROM registry.entitlements e
  JOIN registry.tenants t ON t.id = e.holder_tenant_id
  JOIN registry.offer_versions v ON v.id = e.offer_version_id
  JOIN registry.offers o ON o.id = v.offer_id
  JOIN registry.resources r ON r.id = v.resource_id
  JOIN registry.offer_version_payment_plans p
    ON p.offer_version_id = v.id AND p.id = e.payment_plan_id
 WHERE r.name = 'payment processing'
   AND t.slug = 'registry';
```

Expect one row: `Platform payment processing`, `percentage_of_sales`, `0`,
`active`.

```sql
SELECT v.id, o.name, p.fraction, v.published_at IS NOT NULL AS published
  FROM registry.offer_versions v
  JOIN registry.offers o ON o.id = v.offer_id
  JOIN registry.offer_version_payment_plans p ON p.offer_version_id = v.id
 WHERE v.id = '00000000-0000-0000-0003-000000000001';
```

Expect `Solo`, `0.025`, published.
