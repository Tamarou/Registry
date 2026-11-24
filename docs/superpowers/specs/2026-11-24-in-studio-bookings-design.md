# In-studio bookings — design

Status: draft

Base commit: `main` at 6202ea6 (PriceOps step 3 merged).

Supersedes: no prior draft was available; written from scratch on the PriceOps model, per perigrin 2026-11-24.

Model: `docs/superpowers/specs/2026-11-21-priceops-model-design.md` (branch
`docs/priceops-model-design`), "Order of work" step 7. Where this draft and the
model disagree, the model wins. Rulings already recorded: ADR 003 (direct
charges), ADR 004 (workflow reach), ADR 005 (day-one rulings).

## What this is

A studio (SACP on day one) sells seats in its classes. A person picks a class
occurrence, chooses one of the class's published offers, books N of it, pays,
and holds a booking. Staff see each day's classes and who is booked. The
booking's life (reschedule, refund, expiry, attendance) follows the terms it
was sold under.

Every piece is an instance of the model. Nothing here is a new kind of thing:
a booking is an entitlement, a class's seats are resources, the class's prices
and terms are offer versions, and paying is step 5's accept-and-pay.

## Goals

- Class setup and occurrence generation are product design: workflows an admin
  runs, publishing offers through step 4's steps. No price or policy in code.
- One adult books N seats in one occurrence, within the offer's per-booking
  cap, counted as seats held by entitlements and live holds.
- Payment is a direct charge on the studio's own Stripe account, with the
  platform's `application_fee_amount`. The fee is Solo's 2.5% read from SACP's
  entitlement from the platform, never from a plan name or a per-tenant
  setting.
- SACP's stated terms are offer policies: refund none; change up to 48 hours
  before, fee, targets in the same offer; expiry at the end of the occurrence;
  use as optional attendance.
- The 48-hour change window and the staff day view are measured in the
  studio's time zone.
- A priced payment is refused when the Stripe key or the studio's account is
  missing. `/terms` is served. The session cookie is `Secure` in production.
- In-studio reaches SACP's existing schema by accepting the platform's offer
  (step 6), not by a migration.

## Non-goals

- Extras sold with a booking (aprons, clay, glazes, drinks). Extras are a
  non-goal: they go through the studio's point of sale, outside Registry.
- A per-tenant fee. The only fee is Solo's 2.5%, from SACP's entitlement.
- Destination charges, `transfer_data` or `on_behalf_of` (ADR 003).
- Building on `finalize_enrollment` or `enrollments`. Bookings are
  entitlements created by step 5's accept-and-pay; after-school's
  `Enrollment.pm` path is untouched until step 8.
- Instalments, offer conditions (sibling rates), make-ups, waitlists and
  metering. They arrive with steps 8 and 9.
- A customer "my bookings" screen. The booking's confirmation links its
  reschedule run; staff can reschedule for a customer.
- Recurring memberships or class packs. Each booking is one occurrence.

## The model, mapped

| model | in-studio | where it lives (step) |
|---|---|---|
| product design | class setup; schedule (occurrence generation) | `in-studio-class-setup`, `in-studio-schedule` workflows composing step 4's `offer-publishing` steps (4, 7) |
| class | a named class with default seats per occurrence | a `projects` row, `projects.seats_per_occurrence` (3, `01a20447-8f10`) |
| resource | the seats in one occurrence | an `events` row and its `resources` row (`kind = 'finite'`, `capacity`, `event_id`) (3) |
| offer | "One seat", "Couple (two seats)" for a class | `offers` + `offer_versions` with `class_project_id`, `price_cents`, `currency`, `units_per_acceptance`, `per_booking_cap` (3) |
| payment policy | one-time | `offer_version_payment_plans.kind = 'one_time'` (3) |
| refund policy | none (sales final) | `policies.refund = {kind: none}` (3, 5) |
| change policy | 48 h before, fee, same offer | `policies.change = {kind: window, window_hours: 48, fee_cents, targets: same_offer}` (3, 5) |
| use policy | optional attendance | `policies.use = {kind: optional_attendance}`; use records (5, `01a20416-6d2a`) |
| expiry | at the end of the occurrence | `policies.expiry = {kind: end_of_occurrence}`; the expiry sweep (5, `01a20416-6d03`) |
| hold | seats taken while the booker pays | `holds` row for the booking run (3, 5) |
| entitlement | a booking | `entitlements` (`holder_user_id` = booker, stamped `offer_version_id`, `payment_id`) + `entitlement_units` (3) |
| payment | direct charge on the studio's account | `payments` stamped with `offer_version_id` and `platform_offer_version_id` (2, 5) |
| platform fee | Solo's 2.5% | SACP's `registry.entitlements` row, read by `PriceOps::PlatformTerms` (3) |
| Stripe-reported moves | full refund, partial refund, lost dispute | applied to the entitlement (5, `01a20416-6f62`, `01a20416-6f8d`) |
| right to run in-studio | SACP may run the four workflows | a run entitlement from the platform, accepted (6) |

A class's offers cover every occurrence of the class, current and later
(`OfferVersion->covered_resources`), so generating occurrences publishes no new
offer version. One booking holds seats in exactly one occurrence (the
`entitlement_units` exclusion); seats in two occurrences are two bookings.

## Screens and workflows

| screen / workflow | who | persona | what it does |
|---|---|---|---|
| `in-studio-class-setup` | tenant admin | [Rosa](../../personas/rosa.md) | Defines a class (name, location, seats per occurrence) and publishes one offer for it through step 4's steps. Run again to add another offer to the same class. |
| `in-studio-schedule` | tenant admin | Rosa | Generates a class's occurrences from a weekly pattern in the location's time zone. Idempotent. |
| `in-studio-booking` | anyone (public) | [Sam](../../personas/sam.md) | Occurrence → offer and count → account → hold → pay → booked. |
| `entitlement-change` (step 5) | the booker; staff and admins for them | Sam, [Theo](../../personas/theo.md) | Reschedules a booking within its stamped change policy. |
| `in-studio-day-view` | tenant admin and staff | Theo, Rosa | One studio-local day: occurrences, seats held, bookings; optional attendance. |
| `/terms` | anyone | Sam; [Jordan](../../personas/jordan.md) at signup | The platform's terms of service. |
| platform offer acceptance (steps 5–6) | tenant admin | Rosa; [Alex](../../personas/alex.md) publishes | SACP accepts the Solo version that lists the in-studio workflows; the copies arrive. |
| Stripe dashboard (outside Registry) | tenant admin | Rosa | Refunds and disputes. Registry follows them (step 5). |

### Class setup (`in-studio-class-setup`, admin)

Steps, in order:

1. `class` (new step `ClassBasics`): pick an existing class or create one: name,
   location, default seats per occurrence (whole number ≥ 1). Writes the
   `projects` row and `seats_per_occurrence`. Creates no resource.
2. Step 4's `offer-publishing` steps, with the resource step fixed to "cover a
   class" for this class (`01a20417-bd31`): `offer-basics`, `offer-price`
   (price, `units_per_acceptance`, `per_booking_cap`), `one-time-payment`,
   `refund-policy`, `change-policy`, `use-policy`, `expiry-policy`, `publish`.
3. `complete`: links "add another offer to this class" (a new run with the
   class chosen) and "schedule occurrences" (`in-studio-schedule`).

No step pre-fills a policy; the admin chooses each one. Role entry: `admin`
only. `PublishOfferVersion` also refuses a non-admin (step 4).

### Schedule (`in-studio-schedule`, admin)

One form: class, location, weekdays, local start time, duration (minutes),
first and last date. The `GenerateOccurrences` step creates, for each slot, an
`events` row (`status = 'published'`, `capacity` from the class's
`seats_per_occurrence`) and its occurrence resource. Local times are read in
the location's time zone (below). An existing occurrence at the same
`(project_id, location_id, time)` is skipped, so a re-run over an overlapping
range adds only what is missing and never touches a booked occurrence. The run
reports what it created, skipped and shifted (DST).

### Booking page (`in-studio-booking`, public)

Steps, in order:

1. `occurrence` (`ChooseOccurrence`): the class's future, published
   occurrences with free seats, in local time.
2. `offer` (`ChooseOfferAndUnits`): each current offer version covering the
   occurrence, with price, seats per unit and its policies in plain words
   ("Sales are final." "Reschedule up to 48 hours before, for $X.") read from
   the version's `policies`; a link to `/terms`. No offer is preselected. The
   count is 1 to the offer's `per_booking_cap`. The total is shown with the
   quote.
3. `account` (`AccountCheck`, as today): sign in or create an account.
4. `hold` (`HoldSeats`): re-checks the occurrence and offer, then
   `PriceOps::Hold->place` for count × `units_per_acceptance` seats, expiring
   after the hold lifetime (configuration, 15 minutes by default). Writes the
   server-owned run data step 5's `OneTimePayment` reads:
   `{ offer_version_id, payment_plan, amount_cents, description, purpose }`,
   with `amount_cents` = count × `price_cents`. A resubmit keeps the one hold.
5. `payment` (`OneTimePayment`, step 5): a direct charge on the studio's own
   Stripe account with `application_fee_amount` = 2.5% of the amount, from
   SACP's Solo entitlement, omitted when it rounds to 0 (ADR 003).
6. `complete` (`CompleteBooking`, gap G2): on `payment_intent.succeeded`
   (return callback or the Connect webhook's driver), converts the hold into
   the booker's entitlement through `Hold->convert` with its payment link set
   at insert. Idempotent.
7. `done`: the booking, its policies, and a "reschedule" link that starts
   `entitlement-change` for this entitlement.

The workflow carries the public mark in its role data. No extras are offered.

### Change (`entitlement-change`, step 5)

Bookings reuse step 5's workflow unchanged: choose target → hold target → pay
fee → complete. Step 7 changes only how the window is measured (in the
location's time zone, below). See "Change workflow for a booking".

### Day view (`in-studio-day-view`, admin and staff)

One step (`DayView`) for one location (the only one, when there is one) and a
local date in its zone (default today there): that day's occurrences in local
start order, each with
capacity, seats held (active entitlements' units plus live holds, by
`Resource->free_units`) and its bookings (booker, count, seats). Each booking
has an optional "present" mark that calls step 5's `RecordEntitlementUse`.
Nothing else is editable. A malformed date is a 400.

### `/terms`

A route in `lib/Registry.pm` rendering `templates/terms.html.ep`, anonymous, on
the apex and every tenant host. It states the platform's terms only. Until
perigrin supplies the text it is a marked DRAFT placeholder, and production
checkout is refused while the placeholder stands (ADR 005, ruling 12).

## Data

New:

| change | where | owner |
|---|---|---|
| `locations.time_zone text NOT NULL`, a validated IANA name | every tenant schema and `registry`; sqitch `location-time-zone` | `01a20415-6a4f` |

Read or written, not changed:

| table | how in-studio uses it |
|---|---|
| `projects` (`seats_per_occurrence`) | the class |
| `events` (`time`, `duration`, `capacity`, `status`, `location_id`) | an occurrence; `time` stays an instant |
| `resources` (`event_id`, `capacity`) | an occurrence's seats |
| `offers`, `offer_versions`, `offer_version_payment_plans` | a class's offers |
| `holds` (`workflow_run_id`, `expires_at`, `state`) | seats held while paying, booking or change |
| `entitlements`, `entitlement_units`, `entitlement_refunds` | bookings |
| use records (`01a20416-6d2a`) | attendance |
| `payments` (`offer_version_id`, `platform_offer_version_id`) | the charge and its stamps |
| `registry.entitlements` | SACP's Solo terms (fee) and run rights |

Seats per booking: count × `units_per_acceptance`. The cap is on count. The
seats are the booker's (`holder_user_id`); a friend in the second seat has no
record, which day one does not need.

## Decisions for step 7

### Where the time zone lives

On `locations`, as `time_zone` (IANA name). An occurrence is an `events` row
whose `location_id` is `NOT NULL`, so its local time is a same-schema join
(`e.time AT TIME ZONE l.time_zone`) with no read of `registry.tenants` and no
cross-schema key. A place has a zone; a business with rooms in two zones then
needs no second design. "The studio's time zone" in the issues means its
location's.

### Default time zone for existing rows

The migration sets existing rows to `America/New_York`: SACP's one location is
in Orlando, FL (`sql/seed/sacp-tenant.sql`), and every other row is test or
development data. New rows get no default; the column is `NOT NULL` and
location creation asks for it, because a silent UTC default would mis-time
every class (absence is not zero). The location-creation and
location-management workflows gain the field (`01a20415-6a4f`).

### DST rule for occurrence generation

A local start that does not exist (02:30 on the spring-forward day) moves
forward by the gap, to 03:30 local, and the run reports the shift. A local
start that occurs twice (01:30 on the fall-back day) is the first one, the
earlier instant (EDT), giving exactly one occurrence. Generation computes
these explicitly and tests pin both; it never relies on a library's unstated
choice.

### Occurrence generation range limit

At most 366 days from the first date to the last in one run; longer ranges are
refused with a message and create nothing. A weekly pattern then yields at
most 7 × 53 slots per run. A studio schedules a season at a time, and an admin
extends by running it again, which is idempotent.

### Where occurrence generation runs

A sibling product-design workflow, `in-studio-schedule`, not a step of class
setup. Class setup publishes offers; scheduling is repeated each season and
must not republish anything. Both are admin-only. Class setup's last page links
to it.

### DST rule for the 48-hour change window

The cutoff is the occurrence's local start minus `window_hours` on the wall
clock, in the location's zone: a 10:00 class on the spring-forward Sunday
closes at 10:00 local on Friday, as the customer reads "48 hours before". A
cutoff that lands on a nonexistent local time uses the generation rule
(forward by the gap). The boundary is inclusive, `now <= cutoff` allows the
change (ADR 005, ruling 8b), with one shared comparison for display and
server. `window_hours` is read from the stamped offer version, never
hard-coded.

### Change workflow for a booking

Step 5's `entitlement-change`, with no in-studio fork. `01a20415-6bae` changes
the window check inside `ChooseChangeTarget` and `HoldChangeTarget` to the
local rule above. The role entry `[parent, admin, staff]` already admits an
adult booker, whose account `AccountCheck` creates as `parent` (gap G6). A
booker starts it from the booking's `done` page; staff start it for a customer
from the day view.

### Per-booking cap default

No default. `offer_versions.per_booking_cap` is `NOT NULL` with no column
default, and step 4's `offer-price` step requires it, so the admin enters a
whole number ≥ 1 for each offer. A blank is refused, never read as 1 or as
unlimited (absence is not zero). On the booking page the count starts at 1.

### Session cookie SameSite value

`Lax`. The Stripe return after 3-D Secure and the magic-link login are
top-level GET navigations, which carry a `Lax` cookie; `Strict` would drop the
session on both. `None` would send it on cross-site POSTs. The cookie is
`Secure` and `HttpOnly` in every mode but `development` and `test`
(`01a20415-6afa`).

### What /terms says

The platform's terms only. A studio's booking terms differ per offer version
and are stamped on each booking, so they are shown where the customer chooses
(the booking page) from `policies`, not on one page that would go stale. Until
perigrin supplies the text, `/terms` is a marked DRAFT placeholder and
production checkout is refused (ADR 005, ruling 12; gap G8).

### How the in-studio offer is published

By an admin run, not bootstrap data. The model's bootstrap creates only the
root and Solo v1, and "nothing after it is created any other way". Alex runs
`offer-publishing` on `registry` to publish the Solo version that adds the
in-studio run rights (ADR 004, ruling (a)); the test publishes it through the
same workflow (`publish_offer`). SACP's admin then accepts that version, which
brings the copies (step 6). This needs an offer version that buys a set (gap
G1).

### Day view as route or workflow

A workflow, `in-studio-day-view`. Step 6's gate then applies as it does to the
other three: roles as data (`admin`, `staff`) and the run entitlement, so a
tenant that has not accepted in-studio has no day view. A route would need its
own role and entitlement checks. `admin-dashboard` is the precedent. The cost
is a run row per visit; acceptable for day one.

### Workflow slugs and file names

| thing | slug / path |
|---|---|
| class setup | `in-studio-class-setup`, `workflows/in-studio-class-setup.yml`, `templates/in-studio-class-setup/` |
| occurrence generation | `in-studio-schedule`, `workflows/in-studio-schedule.yml`, `templates/in-studio-schedule/` |
| booking | `in-studio-booking`, `workflows/in-studio-booking.yml`, `templates/in-studio-booking/` |
| day view | `in-studio-day-view`, `workflows/in-studio-day-view.yml`, `templates/in-studio-day-view/` |
| change | `entitlement-change` (step 5) |
| terms | route `/terms`, `templates/terms.html.ep` |
| time zone migration | sqitch `location-time-zone` |
| new step classes | `ClassBasics`, `GenerateOccurrences`, `ChooseOccurrence`, `ChooseOfferAndUnits`, `HoldSeats`, `CompleteBooking`, `DayView` under `lib/Registry/DAO/WorkflowSteps/`, each on the step-class allowlist |

### Late payment after the hold lapsed

The payment succeeds after the hold lapsed and the seats were resold. Stripe
has the money; Registry never contradicts Stripe and never re-charges.

| option | effect |
|---|---|
| A. Refund automatically and notify the booker and staff | No overbooking. A system-started refund under a "refund: none" offer; that policy governs the customer's cancellation, not our race. |
| B. Grant over capacity | Honours the payment; the class is over capacity and staff sort it out on the day. |
| C. Hold the money, flag for staff | No automatic action; the customer waits on a person. |

Recommendation: A, as ADR 005 ruling 7a records from the session on
2026-11-22. Re-take the seats under lock first if they still fit, and refund
only if they do not. The refund keeps the platform's fee, like every refund
(ADR 003). No step in steps 3–6 starts this refund (gap G3).

Awaiting perigrin's answer.

### Paid amount differs from the quote

A `payment_intent.succeeded` whose amount differs from the hold's quote.

| option | effect |
|---|---|
| A. Refuse, refund, alert staff and the platform | No booking at a wrong price. Staff can book by hand at the right price. |
| B. Grant anyway | Trusts Stripe's amount; a wrong price stands. |
| C. Flag for staff, no refund | The booker holds nothing and the money sits until a person acts. |

Recommendation: A, as ADR 005 ruling 7b records. A mismatch means the intent
was altered or the quote changed under it; neither should create an
entitlement. The refund is the same system-started refund as above (gap G3).

Awaiting perigrin's answer.

### Fee rounding

Rounding of the 2.5% fee to whole cents.

| option | 32.5¢ | 37.5¢ | in whose favour |
|---|---|---|---|
| A. Half to even (banker's) | 32¢ | 38¢ | neither, on average |
| B. Half up | 33¢ | 38¢ | the platform |
| C. Down (truncate) | 32¢ | 37¢ | the studio |

Recommendation: A, as ADR 005 ruling 7c records and as step 2 already
implements (`Registry::DAO::Payment::application_fee_cents`, integer basis
points). The fee is computed once at quote time; the displayed fee,
`application_fee_amount` and the recorded fee are that one number, omitted
when it is 0.

Awaiting perigrin's answer.

## Gaps

Gaps in steps 3–6 that step 7 needs. Named here, not designed around.

| # | gap | evidence | who closes it |
|---|---|---|---|
| G1 | An offer version buys one resource (`offer_versions` has `resource_id` or `class_project_id`, `CHECK num_nonnulls = 1`). ADR 004 ruling (a) needs a Solo version that lists a set of workflow run rights. No step 3–6 issue relaxes it. | `sql/deploy/priceops-occurrence-resources.sql`; ADR 004 "Consequences" | new issue before `01a20415-6c2f` |
| G2 | No step turns a paid booking hold into an entitlement. `OneTimePayment` "creates no entitlement itself"; `CompleteChange` is change-only; the signup accept is platform-only. `Hold->convert` exists (`01a20416-6e1b`) but nothing calls it for a booking. | `01a20416-6df2`, `01a20416-6e51`, `01a20416-6d40` | `01a20415-6b96` adds `CompleteBooking` |
| G3 | No system-started refund for a booking payment. ADR 003 names `SupersededRefund` as "the one refund Registry starts on its own"; rulings 7a and 7b would add two more. | ADR 003, ADR 005 7a/7b | `01a20415-6b96`, after perigrin's answers above |
| G4 | `OfferVersion->covered_resources` and `buys` ignore `events.status` and `events.time`, so a grant into a closed or past occurrence is accepted. | `lib/Registry/DAO/OfferVersion.pm`; note on `01a20415-6b4a` | `01a20415-6b4a` (its note AC) |
| G5 | `Resource->for_occurrence` copies `events.capacity`, and fails `resources_capacity_matches_kind` when it is NULL. | `lib/Registry/DAO/Resource.pm`; note on `01a20415-6b12` | `01a20415-6b12` sets `capacity` from `seats_per_occurrence` |
| G6 | No adult-customer role. `users.user_type` and `tenant_users.role` allow `parent`, `student`, `staff`, `admin`; `AccountCheck` creates adults as `parent`. Day one uses `parent`; the name is wrong for an adult booker. | `sql/test-schema.sql` `check_user_type`; `AccountCheck.pm:33` | later; not day-one |
| G7 | ADR 005 ruling 8b makes the change boundary inclusive (`now <= boundary` allowed), but `01a20415-6bae`'s negative subtest is `change at exactly the window refused`. | ADR 005 8b | update `01a20415-6bae` |
| G8 | ADR 005 ruling 12 (DRAFT placeholder, production checkout refused while it stands, an agreement step and terms versioning) has no issue, and `01a20415-6ae1`'s subtest `terms page has no placeholder text` contradicts it. | ADR 005 12 | split `01a20415-6ae1` |

## What `t/priceops/day-one.t` exercises from the in-studio side

Under the placeholder key, no skips, through the real workflows
(`01a20415-6d02` parts 3 and 4):

1. SACP, provisioned as `sql/seed/sacp-tenant.sql` does, accepts the Solo
   version listing the in-studio workflows and holds their run rights and
   copies.
2. An SACP admin runs `in-studio-class-setup`: one class, a one-seat offer with
   a one-time plan, `per_booking_cap`, and SACP's four policies.
3. The admin runs `in-studio-schedule`; occurrences exist with the class's
   seats.
4. A visitor runs `in-studio-booking` for N units of the offer: N ×
   `units_per_acceptance` seats are held, and the quoted fee is 2.5% of the
   amount, half to even, read from SACP's Solo entitlement (subtest
   `booking holds seats and quotes the solo fee`).
5. Negatives: `studio and empire not published`, `tenant without solo cannot
   charge`, `other tenant cannot see sacp booking`.

Not in `day-one.t`: the live direct charge and the booker's entitlement
(`t/stripe-live/day-one-direct-charge.t`, `sk_test_` key); the change window,
day view, cookie and `/terms` (each in its own issue's tests).

## Order of work

Aligned with the `[S7]` issues of milestone `priceops-day-one`. Each issue's
"details follow the approved draft" means its body is updated from this
section before it starts.

| # | issue | from this draft |
|---|---|---|
| 0 | `01a20415-6a43` this draft | perigrin's approval |
| 1 | `01a20415-6a4f` time zone | on `locations`; sqitch `location-time-zone`; default `America/New_York` for existing rows; location-creation and location-management gain the field |
| 2 | `01a20415-6afa` Secure cookie | `SameSite=Lax` |
| 3 | `01a20415-6ac5` refuse priced payment without key or account | as written |
| 4 | `01a20415-6ae1` `/terms` | split (below) |
| 5 | `01a20415-6a6d` class setup | slug `in-studio-class-setup`; `ClassBasics` + step 4's steps; no pre-filled policy |
| 6 | `01a20415-6b12` occurrence generation | sibling workflow `in-studio-schedule`; DST and 366-day rules; G5 |
| 7 | `01a20415-6aab` seats held, not family members | as written |
| 8 | `01a20415-6b4a` booking workflow | slug `in-studio-booking`; steps above; G4 |
| 9 | `01a20415-6b96` direct charge | adds `CompleteBooking` (G2); the money rules once perigrin answers (G3) |
| 10 | `01a20415-6bae` change window | wall-clock rule; inclusive boundary (G7); no new workflow |
| 11 | `01a20415-6bf2` day view | workflow `in-studio-day-view` |
| 12 | `01a20415-6c2f` offer the in-studio workflows | admin run of `offer-publishing` on `registry`; needs G1 |
| 13 | `01a20415-6d02` `t/priceops/day-one.t` | as above |

Issues to add or split, for the orchestrator:

- **Add** `[S6] Let an offer version buy a set of resources` (G1), blocking
  `01a20415-6c2f`.
- **Split** `01a20415-6ae1` into `[S7] Serve /terms with a marked DRAFT
  placeholder and refuse production checkout while it stands` and `[S7]
  Replace the /terms placeholder with perigrin's text` (`gate:perigrin`).
- **Add** `[S7] Record which terms version a booker agreed to` (ADR 005
  ruling 12's agreement step and terms versioning), before `01a20415-6b96`.
- **Update** `01a20415-6bae`: subtest `change at exactly the window refused`
  becomes `change at exactly the window allowed` (G7).
- **Update** `01a20415-6b96`: add `CompleteBooking` to its paths (G2) and the
  refunds for late payment and amount mismatch once perigrin answers (G3).
- **Update** `01a20415-6a4f`: the zone is on `locations`; paths gain
  `lib/Registry/DAO/Location.pm` and the location workflows.
