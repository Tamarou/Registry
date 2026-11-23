<!-- ABOUTME: Step 0 spike of the PriceOps day-one milestone: what is red once CI can install. -->
<!-- ABOUTME: The deliverable is this list; the fixes are the split issues of 01a20410-d044. -->

# Step 0 spike: what is red on `main`

Commit: 16ca8b8b3af7d998f0cdf71e21b2a2d189b0c898
Green: 28c9f0c1d728a6c35a92f574c4275912eff8fb05

That commit is `main` (4e6664b) plus PR #500's CI and dependency changes
(`Mozilla::CA` pinned, DBD::Pg 3.18.0 → 3.21.2, CI build-log extract, dead
`~/perl5` cache removed). No application or test code differs from `main`.

## How it was taken

| run | where | toolchain | result |
|---|---|---|---|
| CI sweep, `prove -lr -j"$(nproc)" t/` | GitHub Actions run 45048275587, job `test` | Perl 5.42.3, PostgreSQL 18 (runner image Ubuntu 26.04), DBD::Pg 3.21.2 | Files=368, Tests=2866, **1 file red** |
| `make test` | this container, `LC_ALL=C.UTF-8` | Perl 5.42.0, PostgreSQL 16, DBD::Pg 3.21.2 | Files=361, Tests=2834, 2 files red |
| CI sweep, `prove -lr -j8 t/` | this container, `LC_ALL=C.UTF-8` | as above | Files=368, Tests=2866, 2 files red |
| every file alone, stderr captured per file | this container, `LC_ALL=C.UTF-8` | as above | 366 of 368 exit 0; the same 2 red |

The CI run is the authority for "red on `main`". The local runs supply
per-file reruns and the noise attribution below.

Local caveats, so the local numbers are not mistaken for regressions:

- **Locale.** Under this container's default POSIX locale, `make test`
  reported about 58 red files (Files=361, Tests=1799), almost all "Wide
  character in subroutine entry" when a test imports templates. Under
  `LC_ALL=C.UTF-8`, which the CI runner has, they pass. Nothing in the
  Makefile pins a locale; that is a cluster below.
- **Dependencies.** This container reaches only `www.cpan.org`, so five
  snapshot-pinned distributions that now live only on BackPAN (DBI 1.647,
  Object-Pad 0.820, Function-Parameters 2.002005, Text-CSV_XS 1.61,
  YAML-LibYAML 0.903.0) are installed locally at their current versions. CI
  installs the exact snapshot.

## Clusters

| cluster | what | files | fix |
|---|---|---|---|
| `platform-row-ages-into-inert-report` | The seeded `registry-platform` row in `sql/test-schema.sql` has a fixed `created_at`; once it is older than the test's ten-day window, `Tenant::inert` (which excludes only `slug <> 'registry'`) reports the platform as an abandoned tenant. | `t/dao/inert-window-configurable.t` | Already written: PR #499, commit 9ce0ad9 ("The platform's own rows are not tenants to reclaim, bill or chase"), open and mergeable. Merge #499 or port that commit. Step 1 (collapsing the two platform rows) later removes the need for its slug list. |
| `ci-playwright-on-ubuntu-26-04` | CI environment, not a test: Playwright 1.55.1 refuses `ubuntu26.04-x64` ("does not support chromium"), so the `e2e` (playwright.yml) and `stripe-e2e` (stripe-e2e.yml) jobs stop at "Install Playwright browsers" before any test. | none (workflows) | Pin `runs-on` for those jobs to an image Playwright supports, or move Playwright to a release that supports 26.04. |
| `test-locale-not-pinned` | `make test` inherits the shell's locale; under POSIX ~58 files fail on wide characters. CI happens to be UTF-8. | none (Makefile) | Export a UTF-8 locale in the Makefile's `test` target. |
| `local-network-only` | Red only in this container: the test makes a real call to `api.stripe.com` with the placeholder key and expects Stripe's own error; here Mojo::UserAgent resolves DNS directly instead of through the egress proxy ("Can't connect: Name or service not known"). Green on CI. | `t/service/stripe-async-bug.t` | None needed for `main`. Recorded so a local run is not misread. |

Red files, one row each:

| file | first failure | cluster |
|---|---|---|
| `t/dao/inert-window-configurable.t` | `the window decides what is reported` → `at thirty, the sixty-day-old one is`: `$got->[1] = 'registry-platform'`, expected not to exist (line 127; also `at ten, both`, line 131) | `platform-row-ages-into-inert-report` |

## CI sweep only

none. The CI sweep and `make test` fail on the same file. (`t/stripe-live/`
is in the sweep and skips without an `sk_test_` key, as designed.)

Red locally but not on CI (environment, not `main`):

| file | first failure | cluster |
|---|---|---|
| `t/service/stripe-async-bug.t` | `Error is from Stripe API, not async handling`: got `Can't connect: Name or service not known` | `local-network-only` |

## Noisy output

These pass but print warnings or unexpected output, which CLAUDE.md does not
allow ("Test execution must be pristine"). Attributed by running each file
alone with stderr captured.

Perl warnings (unambiguous noise):

| file | output | source |
|---|---|---|
| `t/integration/utf8-encoding.t` | `Wide character in print at .../Test2/Formatter/TAP.pm line 156` | test prints non-ASCII without a UTF-8 output layer |
| `t/integration/utf8-workflows.t` | same | same |
| `t/dao/drop-refund-is-a-request-not-a-refund.t` | `Use of uninitialized value $user_role in string eq/ne` | `lib/Registry/DAO/Enrollment.pm` lines 692 and 708 |
| `t/controller/tenant-domains.t` | `Name "MockRenderService::verify_custom_domain" used only once: possible typo` | the test, line 236 |
| `t/controller/payment-return-callback.t` | `Un-mocked method 'unsettled_refund_increments()' called` | a Test::MockObject reaching `lib/Registry/DAO/WorkflowSteps/Payment.pm` line 447 |
| `t/controller/workflow-layout-issues.t` | `(in cleanup) Can't call method "FETCH" on an undefined value at .../Mojo/Pg/Database.pm line 35 during global destruction.` | a database handle outliving its connection at exit; also twice in the CI sweep log |

Errors printed from deliberately exercised failure paths (the assertion
passes; the message reaches stderr instead of being captured and checked):

| file | output |
|---|---|
| `t/controller/camp-registration-errors.t` | `duplicate key value violates unique constraint "users_username_key"` from `AccountCheck.pm` line 33 |
| `t/dao/parent-dashboard.t` | `Failed to send email notification ...: No email found for user ...` (`Message.pm` line 89) |
| `t/job/attendance-check.t` | `No app context available for scheduling next run` (`ScheduleNext.pm` line 53) |
| `t/unit/email-templates.t` | `Unknown email template: 'nonexistent_template'` |
| `t/robustness/db-constraints.t` | constraint-violation `DETAIL:` lines from `User.pm` line 208 |
| `t/database/seed-tier-pricing-options.t`, `t/database/retire-registry-plus-plan.t` | `psql:` pre-flight `ERROR:` lines and `Deploy failed` from migrations the tests expect to refuse |
| `t/dao/enrollment-capacity-partial-fit.t`, `t/dao/payment-capacity-obligation.t` | `finalize_enrollment: unresolvable refund share for child ... in session ... (payment ...)` |
| `t/dao/payment-refund-increments.t` | `record_capacity_obligation: no headroom for 2500 cents on payment ...` and `refusing negative share -2500` |
| `t/dao/payment-step-readiness-gate.t`, `t/integration/tenant-paid-enrollment.t`, `t/user-journeys/alex/02-activate-and-collect.t` | `checkout refused: tenant '...' is not Stripe Connect ready, so a priced cart cannot be charged` |

`diag` output on stderr from files that pass (lines beginning `#`, which a
TAP harness shows but does not count as failure):

| file | `#` lines |
|---|---|
| `t/dao/waitlist-position-debug.t` | 52 |
| `t/dao/waitlist-rapid-test.t` | 27 |
| `t/e2e/admin-program-management.t` | 8 |
| `t/user-journeys/alex/03-platform-billing.t` | 2 |
| `t/database/enrollment-reenrol-tenant.t` | 1 |
| `t/controller/stripe-connect-onboarding.t` | 1 |

How this section was derived, so it can be re-derived: each file run alone
with `carton exec perl -Ilib <file>` under `LC_ALL=C.UTF-8`, stderr captured
per file; a file is listed above if its stderr has any line that is not a
`#` diagnostic, blank, or a structured `{"level":...}` log line, or (for the
`diag` table) if it passed and printed `#` lines. Every such file is listed.

Application log lines (structured JSON on stderr) appear in most controller,
security and user-journey files: `MOJO_SECRET not set -- using hostname for
development only` (warn, about 200 times), five `Scheduled recurring ... job`
info lines per app start, and error lines from refused webhooks and
production-configuration checks the tests provoke on purpose. They are one
cause, not one per file: the test app logs to stderr at its default level.
Whether the suite silences them (a test log level) or asserts them is the
green issue's call.

## Green

Recorded 2026-11-22 at 28c9f0c. On it CI's `test`, `e2e`,
`database-compatibility` (16/17/18), `lint` and `security` jobs all pass, as
do `stripe-e2e`'s six real-Stripe Perl suites (both already true at 5059670);
28c9f0c is the first commit on which the Playwright seeder also succeeds, so
the browser leg reaches the payment step. Locally, `make test`
and the `-j8` sweep are clean except `t/service/stripe-async-bug.t`, which
needs the network and passes in CI. Not green at this point, by perigrin's
decision to close step 0 here: the browser leg of `stripe-e2e`
(`t/playwright/payment-smoke.spec.js`), where the Stripe Payment Element
never renders. It is filed as its own issue, as is the unexplained
IO::Socket::SSL load-order failure in the Playwright seeder.
