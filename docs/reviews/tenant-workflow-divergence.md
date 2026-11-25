# Tenant workflow divergence report

The step-6 report the spec requires: "Before any tenant copy is replaced, the step lists tenant workflows whose slug, steps, classes or templates differ from the platform's and reports them to perigrin." It is git-zhi issue 01a20415-6983.

- Date: 2026-11-25T15:22:22Z
- Database: production (host `dpg-ckq1i8o5vl2c73d61070-a.oregon-postgres.render.com`, PostgreSQL 18.6)
- Command: `carton exec ./registry workflow divergence registry`
- Git SHA: f9620f255ac90a6f386fbf9d82034abd6d3cc52d
- Run by: the `rebel` session on perigrin's machine, at perigrin's request.
  - It used the Dockerfile image built at that SHA, with the entrypoint overridden so `sqitch deploy` never ran.
  - Every connection was read-only: `PGOPTIONS='-c default_transaction_read_only=on'`, on top of the command's own setting.
  - Nothing was written to production.

## Output (verbatim)

```
# Tenant workflow divergence

```

There are no tenant sections, because production has no studio tenants. The `rebel` session confirmed this with read-only queries against the same database:

- `registry.tenants` has one row, `registry`, which the report excludes by design.
- `pg_namespace` has no tenant schemas.
- `registry.workflows` has 34 rows.

Since #503 collapsed the platform tenant, only the platform remains. SACP's hand-seeded schema (`sql/seed/sacp-tenant.sql`) has not been applied to production.

Template diffs: none, since no difference was listed.

Reported to perigrin on 2026-11-25 via https://claude.ai/code/session_01V7rs98q3bwA7Cs9ZBpVuL5

## Rulings

Nothing differs, so no ruling is needed for any difference. Awaiting perigrin's acknowledgement.
