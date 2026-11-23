#!/usr/bin/env perl
# ABOUTME: Runs each test file that used to print stray stderr while passing and fails, naming it, if it still does.
# ABOUTME: Expected errors belong in assertions and debugging in note(), not on the terminal (CLAUDE.md: pristine output).
use 5.42.0;
use warnings;
use Test::More;
use Capture::Tiny qw(capture);

# The files the step 0 note (docs/superpowers/notes/2026-11-22-step0-red-tests.md,
# "Noisy output") found printing to stderr while they passed: errors from
# failure paths they provoke on purpose, and diag() chatter. Each runs alone,
# as the note derived them, so one file's output cannot hide behind another's.
my @files = qw(
  t/controller/camp-registration-errors.t
  t/dao/parent-dashboard.t
  t/job/attendance-check.t
  t/unit/email-templates.t
  t/robustness/db-constraints.t
  t/database/seed-tier-pricing-options.t
  t/database/retire-registry-plus-plan.t
  t/dao/enrollment-capacity-partial-fit.t
  t/dao/payment-capacity-obligation.t
  t/dao/payment-refund-increments.t
  t/dao/payment-step-readiness-gate.t
  t/integration/tenant-paid-enrollment.t
  t/user-journeys/alex/02-activate-and-collect.t
  t/dao/waitlist-position-debug.t
  t/dao/waitlist-rapid-test.t
  t/e2e/admin-program-management.t
  t/user-journeys/alex/03-platform-billing.t
  t/database/enrollment-reenrol-tenant.t
  t/controller/stripe-connect-onboarding.t
);

for my $file (@files) {
    my ( $stdout, $stderr, $exit ) = capture {
        system $^X, '-Ilib', '-It/lib', $file;
    };

    # A passing file has nothing to say on stderr. Blank lines are layout; any
    # other line -- an error, a warning, a diag, an application log line -- is
    # output someone has to read past.
    my @stray = grep { /\S/ } split /\n/, $stderr;

    is $exit, 0, "$file passes";
    ok !@stray, "$file prints nothing on stderr"
      or diag join "\n", "first stray lines from $file:",
      map {"  $_"} @stray[ 0 .. ( $#stray < 4 ? $#stray : 4 ) ];
}

done_testing;
