# Claude connector — design

Status: draft

Base commit: `main` at 0b57ffc (#508 merged: entitlements move, and money follows Stripe). Plan against current `main`'s entitlement and payment tables.

Related: ADR 005 (membership role is authority), `docs/specs/auth-system.md`
(passwordless auth, bearer keys, credentials in the tenant schema), the PriceOps
model (`docs/superpowers/specs/2026-11-21-priceops-model-design.md`, branch
`docs/priceops-model-design`) and in-studio bookings
(`docs/superpowers/specs/2026-11-24-in-studio-bookings-design.md`). Where this
draft and the PriceOps model disagree about where data lives, the model wins.

## What this is

A studio owner connects Claude to her Registry tenant and runs her business
by talking to it. She adds Registry as a custom connector in claude.ai, signs
in with her usual passkey or magic link, approves the connection, and from
then on Claude can answer questions from her real Registry data. In the
second phase she can also set things up and change them, but every change
is previewed first and saved only when she confirms it.

Registry hosts two new things on every tenant's own host:

- An **MCP endpoint**: the tools Claude calls.
- An **OAuth 2.1 authorization server**: claude.ai uses it to get a token
  that acts as the signed-in person, in that tenant only.

## Why

perigrin was in the car with SACP's owner while she tried to project future
revenue in a Claude conversation. She was stitching numbers together by hand
from QuickBooks and from rough figures out of Sawyer and Placeful. Once
Registry holds her programs, classes, enrolments, bookings, prices and
payments, Claude should read those numbers directly instead of her
reconstructing them.

The same connection should make it easier to onboard new programs and to run
the business day to day.

## Who it is for

- **Jordan** (`docs/personas/jordan.md`), the studio owner: a tenant admin,
  working in claude.ai on her phone or laptop. She is the reason this exists.
- **Alex**, the platform operator: he administers the `registry` tenant like
  any other tenant admin and connects to it the same way. The platform is
  just a tenant, so the connector has no platform-only path.
- **Staff** (`tenant_users.role = 'staff'`): they may connect and get what
  the `/admin` screens already show them, and nothing more (see Roles).
  Parents and students cannot connect in either phase.

## Goals

**Phase 1: reading.** Claude can answer questions about the tenant's
business from Registry's own data:

- revenue collected, refunds and outstanding instalments, by period;
- revenue already booked for upcoming programs, classes and sessions;
- revenue still possible: open seats multiplied by price;
- enrolment and bookings against capacity, and what is filling and what is
  not;
- waitlists;
- upcoming classes and events.

The tools return structured data. Claude does the projection arithmetic and
the explaining.

**Phase 2: onboarding and changes.** Claude can set up a new program or class
and change existing ones: schedule, capacity, offers and prices, publishing.
It does this through the same workflows and DAOs the admin screens use, with
a preview-and-confirm step before anything is saved.

**Both phases:**

- One connector per tenant, at that tenant's own host.
- Login through the tenant's existing passkey or magic link.
- Each token acts as exactly one person in exactly one tenant, with that
  person's membership role.

## Non-goals

- **Importing QuickBooks, Sawyer or Placeful data.** Claude combines those
  sources through their own connectors (QuickBooks already has one). Registry
  is the source of truth only for its own data.
- **Parent- or student-facing tools.**
- **Cross-tenant or operator tools,** such as the fleet, platform revenue or
  the runbook queue. These would be a platform-only path. If Alex ever wants
  them, they need their own design.
- **A raw SQL or "query anything" tool.**
- **A general JSON API for Registry.** Only the MCP endpoint and OAuth are
  built here.
- **Support for clients other than Claude.** Any spec-compliant MCP client
  should work, but this design is tested only against claude.ai and Claude
  Code.

## Anti-goals

Any of these makes the feature a failure, even if it works:

- **A token reaches beyond its tenant or its person.** If a token issued at
  tenant A works at tenant B, or acts with more authority than the person's
  role, that is a security incident.
- **Claude changes a tenant without explicit confirmation from the person,**
  or a change bypasses the validation the admin screens apply.
- **A second identity system.** Studio users must not need an account
  anywhere but in their own tenant.
- **Children's personal data reaches the model when the question did not
  need it.** In phase 1 this is a firm line (see Data minimization).
- **Revenue numbers that disagree with the admin dashboard** for the same
  period. One query path, one answer.

## Constraints from the codebase

- **Tenancy is decided by the host** (`tenant` helper, `lib/Registry.pm`
  ~269-395): subdomain, then verified custom domain, then `registry`. The
  `X-As-Tenant` header and `as-tenant` cookie also apply when a user is set.
  The MCP and OAuth routes must not honour `X-As-Tenant` or `as-tenant`: a
  token is bound to the tenant it was issued for (see Host and token binding).
- **Credentials live in the tenant schema.** The `passkeys`,
  `magic_link_tokens` and `api_keys` tables are copied into every tenant
  schema, and lookups go through `$c->dao`. OAuth tables follow the same
  rule.
- **Membership role is authority** (ADR 005). Use the `tenant_role` helper
  and `Tenant->role_in`, never `user_type`.
- **Login has no return-to URL.** `require_auth` redirects to a bare
  `/auth/login`, and `complete_magic_link` and the passkey flow land on `/`.
  The authorize endpoint needs a safe return-to, so this design adds one (see
  OAuth). It must be same-origin and relative-path only.
- **`before_dispatch` order:** auth, log context, CSRF, rate limit, then the
  canonical-domain redirect. Each must treat the new routes correctly:
  - **Auth:** the hook already accepts `Bearer`, but it looks the token up as
    an API key and returns 401 when that fails. OAuth access tokens must also
    resolve there; see Token storage.
  - **CSRF:** `/mcp` and `/oauth/token`, `/oauth/register` and
    `/oauth/revoke` are bearer- or client-authenticated, so CSRF is exempt
    for them. The `/oauth/authorize` consent POST is a browser form and keeps
    CSRF.
  - **Rate limit:** `/oauth/token` and `/oauth/register` get the stricter
    login-tier limit.
  - **Canonical redirect:** must not redirect `/mcp`, `/oauth/*` or
    `/.well-known/oauth-*`. A redirect breaks a registered connector URL and
    the POST body.
- **Workflow catch-all** `/:workflow` (~1257): the new routes are declared
  before it.
- **Deployment is prefork** (Render, Mojolicious). The SDK's HTTP transport
  is stateless, which suits this. Do not enable `streaming =>
  subscriptions/listen`.
- **Stack:** Perl 5.42, Object::Pad, Mojolicious 9.40, Mojo::Pg, sqitch
  migrations, Test::Mojo plus Test::PostgreSQL, and strict TDD with a 100%
  pass rate.

## Approaches

- **A. In-app MCP endpoint, with Registry as its own OAuth server (chosen by
  perigrin).** Each tenant host serves `/mcp` and the OAuth endpoints. The
  MCP server is the CPAN `MCP` distribution (Sebastian Riedel; 0.15, July
  2026), mounted with `to_action`. Its HTTP transport has an `auth` callback
  for validating access tokens and `metadata_url` for the protected-resource
  document. The consent page sits behind the existing passkey and magic-link
  login. Tokens live in the tenant schema. Tools call the same DAOs and
  workflows as the admin screens. Cost: we write and test an OAuth server.
- **B. A hosted OAuth provider (WorkOS AuthKit, Stytch or similar) in front
  of an in-app MCP endpoint.** Less security code, but it adds a vendor, a
  bill, and a second home for studio identities. That is the second anti-goal
  above.
- **C. A separate MCP service calling a Registry JSON API with API keys.**
  Registry has no such API, so this builds an API, a service and OAuth
  anyway. Most work, least gain.

## Design

### Endpoints (per tenant host)

| Path | Purpose | Auth |
|---|---|---|
| `GET /.well-known/oauth-protected-resource` | RFC 9728 metadata for `/mcp`: resource URL, authorization server, scopes | none |
| `GET /.well-known/oauth-authorization-server` | RFC 8414 metadata: issuer, endpoints, `S256` only, grant types, registration endpoint | none |
| `POST /oauth/register` | RFC 7591 dynamic client registration | none, rate-limited |
| `GET /oauth/authorize` | Starts the authorization-code flow and shows the consent screen | session, sending people to login with return-to |
| `POST /oauth/authorize` | Consent decision (approve or deny) | session + CSRF |
| `POST /oauth/token` | `authorization_code` with PKCE, and `refresh_token` with rotation | client id; PKCE verifier |
| `POST /oauth/revoke` | RFC 7009 token revocation | client id |
| `POST /mcp` | MCP over streamable HTTP | OAuth access token |
| `GET /admin/connections` | Lists this person's connected apps and revokes them (screen) | session, admin or staff |

**Host and token binding** (my call, settled after the builder check):

- **The flow runs on the canonical host.** The metadata documents, issuer,
  resource and authorize/token endpoints always name the tenant's canonical
  host: its verified custom domain if it has one, otherwise its subdomain.
  That is the connector URL the studio pastes into claude.ai.
  - On a non-canonical host of the same tenant, `/mcp` answers 401, and its
    `resource_metadata` points at the canonical host's document. Claude is
    sent to the right place, not redirected.
  - Login (`/auth/*`) follows the existing canonical redirect. That is safe
    because the flow already started on the canonical host.
- **A token is bound to its tenant, not to one hostname.** It records the
  tenant id and the resource it was issued for (RFC 8707 `resource`).
  - It is accepted on any host that resolves to the same tenant.
  - It is refused on every other tenant's host, including the `registry`
    fallback for unknown hosts.

  This way connections survive a studio adding a custom domain later.
- **The canonical-domain redirect hook must not redirect** `/mcp`,
  `/oauth/*` or `/.well-known/oauth-*`.

### OAuth details

- **Grant:** authorization code with PKCE, `S256` only. `plain` and the
  implicit grant are refused.
- **Clients:** dynamic registration is open, because claude.ai registers
  itself. A registered client can do nothing until a signed-in person
  approves it.
  - `redirect_uris` must be `https`, and the token request must match exactly.
  - Client records are stored per tenant. Unused clients may be pruned.
  - Only RFC 7591 dynamic registration is supported (my call). Newer MCP
    authorization revisions prefer Client ID Metadata Documents, where the
    client id is a URL the server fetches. Those bring outbound fetching and
    SSRF concerns, so they are added only if the claude.ai spike shows
    claude.ai needs them.
- **Consent screen:** shows the client name as the client gave it, labelled
  as unverified, then:
  - the tenant;
  - the person signed in;
  - in plain words, what the access allows.

  Approve and Deny buttons. It uses the design system's classes, not
  utilities.
- **Codes:** single use, about 60 seconds, bound to the client,
  `redirect_uri`, PKCE challenge, user and tenant.
- **Tokens:** opaque random strings, never JWTs. Only a hash is stored, the
  same way as `ApiKey`.
  - Access tokens expire in 1 hour.
  - Refresh tokens rotate on every use. Reusing a rotated refresh token
    revokes that whole grant.
- **Scopes:** `registry:read` in phase 1; `registry:write` is added in phase
  2.
  - The consent screen grants only scopes the person's role allows: staff
    get read-only even after phase 2.
  - The token's scope narrows what the tools allow. It never widens the
    role.
- **Validity:** every MCP request checks that the token is unexpired and
  unrevoked, that the user is still active, and that the user still holds a
  role that may connect.
  - Deactivating a person or removing their membership ends their access on
    the next request.
  - Role is read live on each request, not from the token.

### Login return-to

`/oauth/authorize` without a session redirects to `/auth/login?return_to=...`.
The return-to value:

- must be a relative path on the same host;
- is validated again when it is used;
- is consumed by both the magic-link and the passkey completion paths.

Everything else falls back to `/` as it does today. This also fixes a gap in
`require_auth` for browser users, but rolling it out there is optional.

**Magic links opened in another browser already work.** Jordan's link opens
from her mail app, often in a different browser from the claude.ai tab that
started the flow. Today's flow handles that: the browser that requested the
link polls `magic_link_status` and then completes the login itself through
`magic_link_complete_by_hash`. So the pending authorization request can stay
in that browser's session.

The only change is that `magic_link_complete_by_hash`, `complete_magic_link`
and the passkey completion must honour the validated return-to instead of
always landing on `/`. No server-side pending-authorization table is needed.

### Token storage

New tables are added to every tenant schema, following `passwordless-auth.sql`
(base tables in `registry`, copied with `%I`):

- `oauth_clients`
- `oauth_authorization_codes`
- `oauth_tokens`: access and refresh tokens, each row with its grant, user,
  client, scopes, `expires_at`, `revoked_at` and `last_used_at`.

Provisioning creates them for new tenants, the same way it creates the
existing auth tables.

The `before_dispatch` bearer path has to tell an OAuth access token from an
API key. My call: give OAuth tokens a distinct prefix (`ro_...`, next to
`rk_...`) and dispatch on the prefix. MCP requests authenticate through the
SDK's `auth` callback, which uses the same lookup, so a revoked or expired
token is refused in exactly one place.

### MCP server

- One `MCP::Server` instance per process.
- Tools are registered with input schemas and annotations: `readOnlyHint` on
  every phase-1 tool, and `destructiveHint` and `idempotentHint` where they
  fit in phase 2.
- The handler resolves the tenant from the request host and the person from
  the token. It runs the DAO call as that person, in that tenant's schema,
  gated by role.
- No tool takes a tenant argument.
- Errors come back as tool errors with a plain message. Stack traces and SQL
  never reach Claude.
- `origins` is restricted (DNS-rebinding guard) to claude.ai and the tenant's
  own hosts.
- `metadata_url` points at the tenant's protected-resource document.

### Phase 1 tools (read-only)

These are a starting set. Each wraps queries the admin dashboard already runs
where they exist, so the numbers agree with what she sees on screen.

| Tool | Returns | Built on |
|---|---|---|
| `tenant_overview` | Counts and this month's revenue, as on the dashboard | `DAO::AdminDashboard->get_overview_stats` |
| `list_programs` | Programs or classes with dates, status, capacity, enrolled or booked, waitlist count; range = current, upcoming, all | `Project->get_program_overview`, plus PriceOps classes and offers |
| `get_program` | One program or class: sessions and occurrences, capacity, filled seats, published offers and prices, waitlist count | Project, Session, Event, Offer/OfferVersion, Entitlement |
| `revenue_summary` | Collected, refunded and net by period (day, week, month) over a date range | `payments`, using the same formula as `get_overview_stats` (net of `refund_owed_cents` and `refunded_cents`) |
| `outstanding_instalments` | Instalments due or overdue, with amounts and due dates | `Payment->outstanding_instalments` |
| `booked_revenue` | Money owed but not yet collected, for upcoming programs and classes, by program and by the month it is due (perigrin, 2026-11-25). Collected money is excluded, so this never overlaps `revenue_summary` | entitlements, instalment schedules and outstanding payments on current `main` (#508) |
| `capacity_and_pricing` | For each upcoming program or class: open seats, price per offer, and the revenue if every open seat sold at each offer | sessions/events capacity, offers |
| `enrollment_trends` | Enrolments and bookings over time | `DAO::AdminDashboard->get_enrollment_trends` |
| `waitlists` | Waitlists by program, with counts and offer status | `Waitlist->get_waitlist_management_data`, aggregated |
| `upcoming_events` | Classes and events in a date range, with filled seats against capacity | `Event` queries |

`booked_revenue` and `capacity_and_pricing` are the ones the car conversation
needed. They keep money already committed separate from money only
possible, so Claude never presents the potential figure as the projection.

### Data minimization (phase 1)

- Phase-1 tools return aggregates and program-level data.
- They never return children's or family members' names, birth dates,
  medical or emergency details, or parents' contact details.
- Money is in cents, with the currency.

A roster tool that lists people is deliberately absent from phase 1. If
perigrin wants one later, it gets its own decision: which fields, which
roles, and logging.

### Roles

Money is visible to Jordan and her manager, but not to teachers (perigrin,
2026-11-25). There are two ways to be "high enough" for that:

- **Make the person an admin.** A manager who should run the business can just
  hold `tenant_users.role = 'admin'`. Nothing new is needed.
- **Give a staff member the `finances` permission.** This is new. It is a
  per-membership flag that admins grant on the people screen, for example as a
  `finances` boolean on `registry.tenant_users`, default false.
  - Admins have it implicitly.
  - It has no meaning on parent or student memberships.
  - It goes through one seam, e.g. `Tenant->can_see_finances($db, $tenant,
    $user)`, read live on every request.

**Money tools** are `revenue_summary`, `booked_revenue` and
`outstanding_instalments`, plus the money fields of `tenant_overview` and the
price and potential-revenue columns of `capacity_and_pricing`. They require the
finances check. Without it they are not listed, and the money fields are left
out of the shared tools.

| Who | May connect | Phase 1 | Phase 2 |
|---|---|---|---|
| admin | yes | all read tools | read + write tools |
| staff with `finances` | yes | all read tools | read only |
| staff | yes | read tools, no money | read only |
| parent, student | no: refused at consent | — | — |

**The dashboard follows the same rule.** Today every staff member sees this
month's revenue on the `/admin` dashboard overview and the outstanding
instalments panel. Phase 1 moves both behind the same finances check, so
the screens and the connector never disagree about who sees money. The
billing pages under `$admin_only` stay admin-only.

### Phase 2: onboarding and changes

The design for phase 2 is settled here only to the extent that it shapes
phase 1. Phase 2 gets its own plan once phase 1 is in use.

- **Write tools are two-step:**
  1. `propose_*` validates the request through the same workflow step or DAO
     validation the admin screen uses. It returns a human-readable preview of
     what will change and a single-use change id that expires after about 15
     minutes. It stores nothing else.
  2. `apply_change(change_id)` re-validates against current data and
     applies the change through the workflow or DAO. It refuses if anything
     moved since the preview.
- Claude is told in the tool descriptions to show the preview and ask the
  person before calling `apply_change`.
- My call: use the two-step tools rather than MCP elicitation, because they
  work in every client and leave a server-side record of what was approved.
- **Every applied change is audit-logged** with the person, the client, the
  tool, the preview and the result. The log is visible on
  `/admin/connections`.
- **First candidates:**
  - creating a class or program, with its schedule and occurrences;
  - publishing and changing offers and prices, through PriceOps offer
    versions, never in place;
  - capacity changes;
  - cancelling an occurrence.
- **Refunds and other money movement are not in phase 2.**

### Observability

- Each MCP call is logged with the tool name, the person, the client, the
  duration and the outcome.
- Phase-2 changes go to the audit log.
- Logs never contain token values or the arguments of tools that carry
  personal data.

## Testing

TDD throughout. The existing suite stays at 100%.

- **OAuth unit and controller tests (Test::Mojo):**
  - metadata documents;
  - registration: valid and invalid redirect URIs;
  - the authorize flow: logged out, logged in, deny, approve;
  - PKCE: the right verifier, the wrong verifier, `plain` refused;
  - code reuse refused;
  - token expiry;
  - refresh rotation, including reuse detection;
  - revocation;
  - return-to validation, including off-host and absolute URLs refused.
- **Tenant isolation:** a token from tenant A is rejected at tenant B, and
  also when sent to tenant B's custom domain. `X-As-Tenant` and the
  `as-tenant` cookie are ignored on `/mcp`.
- **Role tests:**
  - plain staff can't see the money tools or the money fields, and staff with
    `finances` can;
  - the dashboard's revenue figure and its outstanding-instalments panel are
    hidden from plain staff and shown to staff with `finances`;
  - only an admin can grant or revoke `finances`, and the change takes effect
    on the next request;
  - a parent cannot complete consent;
  - removing a membership or deactivating a person kills a live token on the
    next call.
- **MCP tests:** use `MCP::Client`, or JSON-RPC over Test::Mojo, against a
  seeded tenant. These cover the tool list, schemas and annotations; each
  tool's output on known data; and errors.
- **Agreement tests:** `revenue_summary` and `tenant_overview` match the
  admin dashboard's numbers on the same seed data.
- **Data-minimization tests:** no phase-1 tool's output contains seeded
  family member names, birth dates or contact details.
- **End-to-end:** a Playwright or manual check that claude.ai can add the
  connector against a staging tenant, sign in, and call a tool. This proves
  DCR, the metadata and CORS against the real client.

## Left to the builder

- **How tools are named and grouped,** within the starting set and its
  rules.
- **SQL for `booked_revenue` and `capacity_and_pricing`.** Read the PriceOps
  model and in-studio bookings design for where bookings, entitlements and
  offer prices live. Wherever the dashboard already has a query, reuse it.
- **The token prefix** (`ro_` is a placeholder), the exact lifetimes within
  the bounds above, and the client-pruning policy.
- **The `/admin/connections` screen's layout,** using the design system.
- **Where the help text sits** that tells a studio owner which URL to paste
  into claude.ai (her canonical host plus `/mcp`).

## Open risks

- **The MCP SDK is young** (0.15). Pin the version in `cpanfile.snapshot`.
  Confirm early, with a spike against claude.ai, that its protected-resource
  and 401 behaviour satisfy claude.ai's connector flow.
- **claude.ai's DCR and redirect URI behaviour** is defined by Anthropic and
  may change. The end-to-end check is the guard.
- **Custom domains.** A tenant that adds a custom domain after connecting
  has tokens issued for the subdomain. They keep working, but the canonical
  redirect must never redirect `/mcp`.
- **`/api/sessions/available`** points at a missing action and sits outside
  any role guard. It was found during recon and is unrelated, but it is the
  only existing `/api` route, so don't model on it.
