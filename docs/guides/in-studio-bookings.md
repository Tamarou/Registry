---
stability: 1
covers:
  - workflows/in-studio-class-setup.yml
  - workflows/in-studio-schedule.yml
  - workflows/in-studio-booking.yml
  - workflows/in-studio-day-view.yml
  - workflows/entitlement-change.yml
  - templates/in-studio-class-setup
  - templates/in-studio-schedule
  - templates/in-studio-booking
  - templates/in-studio-day-view
  - templates/entitlement-change
  - templates/terms.html.ep
---

# Running In-Studio Bookings

How a studio's admin and front-desk staff run in-studio bookings: setting up
classes and their prices, scheduling a season, what customers see when they
book, how payment and rescheduling work, and the staff day view. SACP is the
first studio to use it.

Who each section serves ([personas](../personas/README.md)):

| Persona | Role here | Sections |
|---|---|---|
| [Rosa](../personas/rosa.md) | The studio's owner and admin: sets up classes, prices and the schedule | All |
| [Theo](../personas/theo.md) | Front-desk staff: reads the day, marks attendance, reschedules for customers | [Day view](#8-the-staff-day-view), [Reschedules](#7-reschedules), [Payment](#6-payment-refunds-and-disputes) |

Every path below is typed on the studio's own host, signed in. The approved
design is
[In-studio bookings — design](../superpowers/specs/2026-11-24-in-studio-bookings-design.md),
and the rulings it relies on are in
[ADR 005](../decisions/005-priceops-day-one-rulings.md).

---

## 1. Getting in-studio booking

In-studio booking comes with the platform's **Solo** offer. When a studio
signs up, its admin accepts Solo once, and that acceptance gives the studio
the right to run five workflows:

| Workflow | Path | Who may run it |
|---|---|---|
| Class setup | `/in-studio-class-setup` | admins |
| Schedule | `/in-studio-schedule` | admins |
| Booking page | `/in-studio-booking` | anyone, signed in or not |
| Day view | `/in-studio-day-view` | admins and staff |
| Reschedule | `/entitlement-change` | the booker, admins and staff |

There is nothing to switch on afterwards. A studio that has not accepted Solo
gets no in-studio screens at all, the day view included.

In the shipped code the acceptance happens at signup. There is no separate
screen for a studio that already exists to accept it later; such a studio is
re-created (see `sql/seed/README.md` for SACP in a development database).

## 2. The studio's time zone

Each location records an IANA time zone, such as `America/New_York`. Choose
it on the **Time zone** field when you create a location (`/location-creation`)
or edit one (`/location-management`). The field is required and has no
default: a missing zone would put every class at the wrong hour. SACP's two
existing locations were set to `America/New_York` when the field was added.

Every time on the in-studio screens is the location's local time, and the
zone name is printed next to it, for example `2027-03-14 10:00
(America/New_York)`. Specifically:

- the schedule's start time is read as local time at the chosen location;
- the booking page, the confirmation and the day view show local start times;
- the day view's "day" is a local calendar day, so a class at 23:30 shows on
  the day it starts locally, not on the next day in UTC;
- the 48-hour change window is counted on the location's local clock.

A class's start is stored as a fixed instant. If you change a location's time
zone after scheduling, existing classes keep their instant, so their local
time on screen moves. Set the zone before you schedule.

## 3. Class setup (admins only)

Open `/in-studio-class-setup`. Each run publishes one offer for one class. Run
it again to add another offer to the same class, or to change an offer's price
or terms.

| # | Screen | What it asks |
|---|---|---|
| 1 | Class | **One of my classes**, or **Create a new class** with its name, location and **Seats per occurrence** (a whole number, 1 or more) |
| 2 | Name your offer | A new offer for the class, or one of its offers to publish a new version of |
| 3 | Price your offer | **Price, in cents**, **Currency**, **Units per acceptance**, **Per-booking cap** |
| 4 | How it is paid for | The one-time payment plan |
| 5 | Refunds | The refund policy |
| 6 | Changes | The change policy: none, or a window with a fee |
| 7 | How it is used | The use policy |
| 8 | When it expires | The expiry policy |
| 9 | Review and publish | Every answer, then **Publish** |
| 10 | Offer published | Links to **Add another offer to this class** and to scheduling |

Screens 2 to 9 are the offer-publishing screens, fixed to cover this class.
[Publishing Offers](publishing-offers.md) explains each field in detail.

Things to know:

- **Seats per occurrence** is the class's capacity. Each occurrence you
  schedule gets that many seats.
- **Units per acceptance** is the seats one unit of the offer uses. A
  "Couple" offer uses 2: one booking of one couple takes two seats.
- **Per-booking cap** is how many units one booking may take. It is
  required; a blank is refused, never read as 1 or as unlimited.
- **Price** is per unit. A booking of 3 units at 2500 cents costs $75.00.
- **No policy is filled in for you.** Choose each one. SACP's terms are:

  | Policy | SACP's choice | What the customer reads |
  |---|---|---|
  | Refunds | None | "Sales are final." |
  | Changes | Window, 48 hours, with a fee | "Reschedule up to 48 hours before, for $X." |
  | Use | Optional attendance | "Attendance is recorded but not required." |
  | Expiry | At the end of the occurrence | "The booking ends when the class does." |

- **A published version never changes.** To change a price or a term, run
  class setup again, choose the class and the existing offer, and publish a
  new version. The new version is what the booking page sells from then on.
  Every booking already sold keeps the version it was sold under: its price,
  its change window and its fee.
- An offer covers every occurrence of its class, now and later, so
  scheduling more occurrences never needs a new offer.

## 4. Scheduling occurrences (admins only)

Open `/in-studio-schedule`. One form generates a class's occurrences from a
weekly pattern:

- **Class**
- **Location** (defaults to the class's own)
- **Teacher**: one of the studio's staff or admins; required
- **Weekdays**: one or more
- **Local start time**, such as `10:00`
- **Minutes**: the length, 1 to 1440
- **First date** and **Last date**: at most 366 days apart

**Generate occurrences** creates one published occurrence for each matching
day, each with the class's seats per occurrence. The result screen,
**Occurrences scheduled**, says how many were created and how many already
existed.

**Re-running is safe.** An occurrence that already exists for the same class,
location and start is skipped and left as it was, bookings included. To
extend a season, run the schedule again over a range that overlaps the last
one; only the missing days are added.

**Daylight-saving days.** The rule is fixed and the result screen reports it:

- A start time that does not exist on its day (02:30 on the day the clocks go
  forward) moves forward by the gap, to 03:30 local. The result screen lists
  each such start and the local time it moved to.
- A start time that happens twice (01:30 on the day the clocks go back) is the
  first one, the earlier instant. You get exactly one occurrence, not two.

## 5. The booking page, as the customer sees it

Send customers to `/in-studio-booking`. The screens are:

1. **Choose a class**: every future occurrence that has a current offer and
   free seats, soonest first, with its local start, zone and seats free. A
   full or past occurrence is not listed.
2. **Choose an offer**: each current offer for that occurrence with its price,
   seats per unit, "Up to N per booking", and its policies in the sentences
   shown in section 3. **No offer is preselected**; the customer must pick
   one. **How many** starts at 1 and is refused above the offer's cap. The
   customer must tick "I agree to the terms of service and the offer's
   policies above", which links to `/terms`.
3. **Your account**: sign in, or create an account.
4. **Hold your seats**: the offer, how many, the seats and the total. **Hold
   and continue to payment** holds the seats for 15 minutes. If another
   customer took them meanwhile, the page says "That class no longer has room
   for N".
5. **Pay for your booking**: the card form. When payment starts, the hold is
   extended once, so a card check in progress does not lose the seats.
6. **You are booked**: the offer, how many, the seats, the local start, the
   policies the booking was sold under, and **Reschedule this booking**.

If the hold lapses before the customer pays, the payment screen says "The
seats held for this payment lapsed. Nothing has been charged." and the
customer starts again.

**When the studio cannot take payment yet**, the payment screen says "This
payment cannot be taken right now. Nothing has been charged." This happens
when the platform's Stripe key is not configured, or when the studio's own
Stripe account is not connected and ready. No charge is attempted and nothing
is recorded.

**Terms of service.** `/terms` states the platform's terms of service
(Tamarou LLC, effective 2026-11-26). The booking page asks the customer to agree
to them, and each booking records the version agreed to. The studio's own
booking terms are never on `/terms`; they are shown with each offer on the
booking page.

## 6. Payment, refunds and disputes

**How the money moves.** Each booking is a direct charge on the studio's own
Stripe account. The studio is the merchant of record and the money lands in
its Stripe balance. The platform takes its fee from each charge as a Stripe
application fee.

**The fee.** The fee is 2.5% of the amount, from the studio's acceptance of
Solo. It is not a per-studio setting. It is rounded to whole cents half to
even, so 32.5¢ becomes 32¢ and 37.5¢ becomes 38¢. A fee that rounds to 0 is
not charged. A reschedule's change fee is a charge like any other and carries
the same 2.5%.

**Sales are final.** Under SACP's refund policy nothing is refunded when a
customer cancels or does not come. Registry starts no refund for a booking or
a change fee, with the two exceptions below.

**The two automatic refunds** (ADR 005 rulings 7a and 7b):

- **Late payment, seats gone.** A payment that succeeds after its hold
  lapsed first tries to take the same seats again. If they are still free,
  the customer is booked as normal. If the class is now full, or has already
  started, no booking is made and the customer's whole payment is returned to
  their card automatically. The customer is emailed that they are not booked
  and that the refund can take 5 to 10 business days; the studio's admins are
  alerted.
- **Wrong amount.** A payment for an amount other than the quoted one is
  refused and returned to the card in full, automatically. No booking is made,
  or, for a change fee, the booking does not move. The customer is emailed to
  book or reschedule again; the studio's admins and the platform are alerted.
  If the customer still wants the class, staff can help them book it again at
  the right price.

In both cases the platform's 2.5% fee is not returned to the studio, as on
every refund.

A late **change fee** is handled differently. If the fee is paid after the
hold on the new time lapsed and that time is now full, or the booking ended
first, the booking stays where it was, the fee is kept, and the studio's
admins are alerted ("A paid change could not be made: it needs an admin").
The customer is told the studio will sort it out with them.

**Every other refund, and every dispute, is the studio's to issue in its own
Stripe dashboard.** Registry follows what Stripe reports:

- a full refund ends the booking and frees its seats;
- a partial refund is recorded on the booking, which stays in effect;
- a dispute the studio loses ends the booking.

A refund issued in Stripe is applied whatever the offer's refund policy says;
the policy describes what the studio offers its customers, not what Stripe may
do.

## 7. Reschedules

A booking sold under a change window can be moved to another occurrence of
the same offer:

- **When.** Up to and including the window before the class starts. For
  SACP the window is 48 hours. It is measured on the location's local clock:
  for a 10:00 class on a Sunday, changes close at 10:00 local on the Friday,
  even across a daylight-saving change. The window and fee are the ones the
  booking was sold under; a later price or policy change does not affect it.
- **Where to.** Only other future occurrences of the same offer with room for
  every seat the booking holds.
- **Order.** Choose the booking, then **Choose a new time**: **Hold this
  time** holds the new seats for 15 minutes. Then **Pay the change fee**
  (skipped when the fee is 0), then **Move my booking**. The old seats are
  freed only when the booking moves.

After the window closes, the change screen says "Changes close 48 hours before
the class starts". A booking whose offer allows no changes is refused with
"This booking's offer says it cannot be changed".

**Who may start a reschedule.** The booker starts it from **Reschedule this
booking** on their confirmation page. Staff and admins can start one from the
day view's **Reschedule** button.

**A reschedule that staff start and that carries a fee is currently
refused**, with "This change has a fee, so the booker must start it from
their booking." Who pays the fee when staff move a booking for a customer is
an open decision for the platform owner, and until it is made, only the
booker can run a paid reschedule. Staff can still move a booking whose change
fee is 0. For a paid one, ask the customer to use the link on their
confirmation.

## 8. The staff day view

Open `/in-studio-day-view` (admins and staff). It shows one location and one
local day.

- **Location**: shown only when the studio has more than one; with one
  location it is chosen for you.
- **Day**: defaults to today at that location. Pick another date and press
  **Show**. A date that is not a real date is refused.

The heading names the location, the day and its time zone. Each class that
day, in start order, shows:

- its local start and class name;
- **Capacity** and **Seats held**. Seats held counts booked seats plus seats
  on a live hold by a customer who is paying right now, so it can drop again
  if that customer does not finish;
- each booking: **Booker**, how many were booked, how many seats, and two
  actions.

The two actions per booking:

- **Mark present** records that the booker came. Attendance is optional:
  marking it, or not, changes nothing about the booking, its seats or its
  money. Once marked, the booking shows **Present**. Marking twice does
  nothing more.
- **Reschedule** starts a reschedule for that booking (see section 7,
  including the limit on paid reschedules).

Nothing else is editable on the day view.

## 9. Where the studio's own point of sale takes over

Registry sells seats in classes, and nothing else. Extras such as clay,
glazes, aprons and drinks, and any sale made at the counter, go through the
studio's own point of sale. They never appear on a booking, and the 2.5% fee
does not apply to them.
