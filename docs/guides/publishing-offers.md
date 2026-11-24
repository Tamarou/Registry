# Publishing Offers

How a tenant admin creates a resource and publishes a priced offer, with its
payment plans and policies, through the `offer-publishing` workflow. Every
tenant uses the same workflow: a studio such as SACP for its seats, and the
platform tenant, `registry`, for Solo.

Who each section serves ([personas](../personas/README.md)):

| Persona | Role here | Sections |
|---|---|---|
| [Morgan](../personas/morgan.md) | An admin of a tenant such as SACP, publishing seat offers for its classes | All, with the SACP worked example |
| [Alex](../personas/alex.md) | The admin of the platform tenant `registry`, publishing later Solo versions | All, with the Solo worked example and [Solo versions](#publishing-a-later-solo-version) |

The workflow is defined in `workflows/offer-publishing.yml`; each screen's
checks are in its step class under `lib/Registry/DAO/WorkflowSteps/`. The model
behind it is described in
[Offers and Subscriptions](../architecture/offers-and-subscriptions.md).

---

## 1. Who may publish

Only an admin of the tenant may run `offer-publishing`. The route is gated to
the `admin` role (`workflow_roles` in `lib/Registry.pm`): a staff member of the
tenant, or an admin of a different tenant, gets a 403. Staff run programs; they
do not set prices.

The gate is checked twice more. The **Resource** screen and the **Publish**
step each look up the signed-in user's role in the tenant whose data the run
is in, and refuse anyone who is not its admin:

- "Only an administrator of this tenant can choose what an offer sells"
- "Only an administrator of this tenant can publish an offer"

## 2. Where to start

Open `/offer-publishing` on your tenant's own host while signed in as its
admin. Alex uses the `registry` host. Nothing in the admin UI links to it yet,
so type the path.

Each run publishes at most one offer version. To publish another, start a new
run.

## 3. The screens, in order

| # | Step | Screen title | What it asks |
|---|---|---|---|
| 1 | `resource` | What the offer sells | Which resource the offer sells, or a new one |
| 2 | `offer-basics` | Name your offer | The resource, and a new offer or a new version of an existing one |
| 3 | `offer-price` | Price your offer | Price, currency, units per acceptance, per-booking cap |
| 4 | `one-time-payment` | How it is paid for | Whether a one-time payment is offered |
| 5 | `percentage-of-sales-payment` | A percentage of each sale | Whether a percentage of sales is offered, and its rate |
| 6 | `refund-policy` | Refunds | The refund policy |
| 7 | `change-policy` | Changes | The change policy |
| 8 | `use-policy` | How it is used | The use policy |
| 9 | `expiry-policy` | When it expires | The expiry policy |
| 10 | `publish` | Review and publish | Every answer, then **Publish** |
| 11 | `complete` | Offer published | Confirmation |

Every screen is shown on every run. No answer has a default: each choice must
be made.

### What the offer sells

Under **Resource**, choose one:

| Choice | Use it for | Fields it uses |
|---|---|---|
| Use one of my existing resources | A resource you made before (Solo's "payment processing") | None here; you pick it on the next screen |
| Create a new resource | Seats in one occurrence, or anything else not yet made | **Name**; Finite or Unbounded; **Capacity, for a finite resource**; **Occurrence it is, for a finite resource** |
| Cover every occurrence of a class | One offer for all of a class's occurrences, now and later | **Class, to cover its occurrences** |

A new resource is one of two kinds:

- **Finite: a number of seats or slots.** It needs a capacity, a whole number
  of at least 1. It may also be one occurrence: the list offers only
  occurrences that do not yet have a resource ("That occurrence already has its
  resource" otherwise).
- **Unbounded: limited only by policy, such as payment processing.** It has no
  capacity and no occurrence.

Whether the offer is bound to an occurrence decides which policies it may
carry later (see the [policy table](#the-day-one-policies)). An offer is bound
when its resource is an occurrence or it covers a class.

The resource is created when you continue. Going back and submitting again does
not create a second one.

### Name your offer

Pick the resource under **Resource**; one you just created is already
selected. In class mode this screen instead says which class the offer covers.

If the tenant already has published offers, an **Offer** choice appears:

- **A new offer, named below.** Fill in **Offer name**.
- **A new version of _name_.** The new version keeps the offer's name, and the
  **Price your offer** screen starts from the current version's price. The
  payment and policy screens are asked again.

### Price your offer

| Field | Accepts | Meaning |
|---|---|---|
| **Price, in cents** | A whole number, 0 or more | 2500 is $25.00 |
| **Currency** | A three-letter code | USD by default |
| **Units per acceptance** | A whole number, at least 1 | How many units of the resource one acceptance takes: 2 seats for a couple |
| **Per-booking cap** | A whole number, at least 1 | How many acceptances one booking may take |

Units per acceptance cannot exceed a finite resource's capacity, or, for a
class, the smallest capacity among its occurrences. A class occurrence added
later with less capacity is not checked against offers already published.

### Payment plans

`offer-publishing` offers one-time and percentage-of-sales payment plans only.
Each has its own screen, and an offer may carry either or both. Publishing is
refused unless at least one is offered ("Offer at least one payment plan").

| Plan | Screen | When offered |
|---|---|---|
| One-time payment | How it is paid for | Paid in full at acceptance. Studio offers such as SACP's use this. |
| Percentage of sales | A percentage of each sale | A percentage of each of the holder's sales, never invoiced. **Rate, in percent** from 0 to 100, at most 2 decimal places (2.5 means 2.5%). It is refused, never rounded. Solo uses this. |

A customer chooses among the plans an offer version carries; the entitlement
they get records which plan they took.

### The day-one policies

Each policy has its own screen. The table lists every choice each screen
offers, and which offers may carry it.

| Policy | Choice | Details asked | Allowed on |
|---|---|---|---|
| Refund policy | None: all sales are final | None | Any offer |
| | Full refund until a cutoff before the occurrence starts | **Cutoff, in hours before the start**; a refund asked for exactly at the cutoff is allowed | Offers bound to an occurrence or a class |
| | Keep the fee, unless an administrator makes an exception (`keep_fee_with_admin_exception`) | None | Offers with a percentage-of-sales plan |
| Change policy | None: a booking cannot move | None | Any offer |
| | Window: a booking may move to another occurrence of this offer until a set time before its own | **Window, in hours before the occurrence** (inclusive); **Change fee, in cents** (0 for free) | Offers bound to an occurrence or a class |
| Use policy | Optional attendance: a booking may be marked attended; nothing depends on it | None | Any offer |
| | None: nothing is tracked as use | None | Any offer |
| Expiry policy | At the end of the occurrence | None | Only offers bound to an occurrence or a class |
| | Never | None | Only offers not bound to an occurrence |

A change window moves a booking only to another occurrence of the same offer;
no other target is offered. The change fee is charged as a one-time payment,
so the revenue share applies to it.

A choice the offer cannot carry is refused on its screen with the reason, for
example "A change window needs an offer bound to an occurrence or covering a
class".

### Review and publish

The review screen lists every answer: resource, price, units per acceptance,
per-booking cap, both payment plans, and the refund, change, use and expiry
policies. **Publish** publishes the version.

Publish checks the run's answers again. **Name your offer** can be answered
again after a later screen, so a price or policy that no longer fits the
offer's resource is refused here with the same reason its own screen would
give. Capacity is checked again under lock, so a capacity lowered since the
price screen is caught.

Publish can also refuse with:

| Message | Cause | What to do |
|---|---|---|
| "A newer version of this offer was published since this run began; start again" | Someone published a version of the same offer after this run read its current one | Start a new run |
| "Publishing this would leave signup with no platform offer to tenants, so nothing was saved" | The [platform-offer guard](#the-platform-offer-guard) refused it | Keep the version on "payment processing" with a percentage-of-sales plan |
| "The offer could not be published, and nothing was saved. Please try again." | Any other failure | See the server log for the cause |

## 4. Worked example: SACP's seats (Morgan)

SACP sells seats in each occurrence of a class, on its stated terms: all sales
final, rescheduling up to 48 hours before for a fee, attendance optional. The
amounts below are placeholders.

| Screen | Answer |
|---|---|
| What the offer sells | Create a new resource; Name "Pottery, 2026-12-05 10:00 seats"; Finite; Capacity 10; Occurrence: that class's 2026-12-05 10:00 occurrence |
| Name your offer | That resource; Offer name "Pottery seat" |
| Price your offer | Price 2500; Currency USD; Units per acceptance 1; Per-booking cap 4 |
| How it is paid for | Offered |
| A percentage of each sale | Not offered |
| Refunds | None: all sales are final |
| Changes | Window; Window 48; Change fee 500 (same-offer targets only) |
| How it is used | Optional attendance |
| When it expires | At the end of the occurrence |

To sell the same terms for every occurrence of the class, choose **Cover every
occurrence of a class** instead of creating a resource. The same policies are
allowed, since a class offer is bound to its occurrences.

A refund policy of "keep the fee" is refused on this offer: it has no
percentage-of-sales plan.

## 5. Publishing a later Solo version

Solo is the platform's offer to tenants: version 1 is seeded on the unbounded
resource "payment processing" at $0 with a 2.5% percentage-of-sales plan. Alex
publishes later versions through the same workflow on the `registry` host.
`t/user-journeys/alex/05-publish-solo-version.t` walks it:

| Screen | Answer |
|---|---|
| What the offer sells | Use one of my existing resources |
| Name your offer | payment processing; A new version of Solo |
| Price your offer | Price 0 (pre-filled); Currency USD; Units per acceptance 1; Per-booking cap 1 |
| How it is paid for | Not offered |
| A percentage of each sale | Offered; Rate 2.4 |
| Refunds | Keep the fee, unless an administrator makes an exception |
| Changes | None |
| How it is used | None |
| When it expires | Never |

"Keep the fee" is accepted only because the offer carries a percentage-of-sales
plan. "At the end of the occurrence" is refused: payment processing is not an
occurrence.

After publishing, Solo version 2 is current and version 1 is superseded.
Tenants that already hold version 1 keep its 2.5% rate, and their payments
keep stamping version 1. Signup grants new tenants version 2.

### The platform-offer guard

Registry always keeps one current published platform offer to tenants: a
version on "payment processing" with a percentage-of-sales plan
(`sql/deploy/platform-offer-to-tenants-guard.sql`). The database refuses any
publish that would retire the last one, for example a new Solo version that
declines the percentage-of-sales plan or moves to another resource. The old
version then stays current, and the publish screen says the version would
leave signup with no platform offer to tenants. The database also refuses
renaming the "payment processing" resource while a current platform offer
uses it (`sql/deploy/platform-offer-resource-keeps-name.sql`). Both guards
apply to `registry` only; a tenant's own offers and resources are not affected.

## 6. Published versions are immutable

Once published, a version's terms, payment plans and policies cannot be
edited; the database refuses it.

- **To change a price or a policy, publish a new version.** On **Name your
  offer**, choose "A new version of" the offer. Publishing it supersedes the
  current version; an offer has one current version at a time. Any conditions
  on who may hold the offer carry over from the version it replaces.
- **Entitlements already sold keep their terms.** Each entitlement names the
  version it was sold under, and keeps that version's price and policies after
  a new version is published.
- **A special arrangement is its own version, never an override.** There is no
  field that changes one customer's terms. Because a new version of an offer
  supersedes it for everyone, publish a special arrangement as a new offer,
  not as a new version of the existing one. `offer-publishing` does not set
  conditions on who may hold an offer.
