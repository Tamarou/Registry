# Seed scripts

One-off SQL scripts that pre-populate a tenant with real-world data.
These are not sqitch migrations -- they run by hand against a specific
environment, typically once, when standing up a new customer.

## `sacp-tenant.sql`

Creates (if missing) the `sacp` tenant for Super Awesome Cool Pottery,
clones the registry schema, and seeds:

- Program types: afterschool, summer-camp, workshop, wheel-class,
  pyop, field-trip, birthday-party
- Locations: the SACP studio (930 Hoffner Ave, Orlando) and
  Dr Phillips Elementary
- Draft projects: Summer Camp 2026 and After-School at Dr Phillips,
  Fall 2026

All projects are created with `status = 'draft'` so nothing goes live
until Victoria publishes from the admin dashboard.

The script is idempotent -- running it repeatedly leaves the same rows.

### Usage

Local dev:

    psql registry -f sql/seed/sacp-tenant.sql

Production (Render):

    psql "$PROD_DB_URL" -f sql/seed/sacp-tenant.sql

Safe to re-run on either. Run from a trusted shell (Render shell /
deploy job / your admin laptop), not a developer's CI environment.

### Data currency

This script captures SACP's offerings as of 2026-04-20, scraped from
superawesomecool.com. It's a one-time bootstrap, not a source of
truth -- once Victoria starts authoring programs through the admin
dashboard, the dashboard wins. Don't treat this file as canonical
data or try to keep it in sync with the site.
