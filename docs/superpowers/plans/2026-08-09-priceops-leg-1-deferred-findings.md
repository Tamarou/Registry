# Leg 1 Plan — Deferred Prose Findings

Inaccuracies found in `2026-08-09-priceops-leg-1-safe-deletions.md` that do **not** change what an executing worker does, and are therefore left in the plan rather than corrected there.

The reason is measured. Across review rounds 6-9 the plan accumulated 78 verified findings, and the share introduced by the previous round's own corrections rose 3 → 8 → 9. Rewriting explanatory argument was generating defects at roughly the rate it removed them. From round 10 the plan takes only corrections that change an action; everything else lands here.

**What belongs here:** wrong or stale citations that support an argument rather than direct a step; counts in narrative; claims in commit-message bodies; Coverage Gaps and Self-Review wording; Deviation descriptions; anything where the worker's next keystroke is the same either way.

**What does not:** line numbers and ranges a step follows, step ordering, code, SQL, commands, gate patterns and match counts, `git add` file lists, safety constraints. Those are corrected in the plan.

---

## Open

### Global Constraints — "Several steps here expect `0`" from a `grep -c`
**Found:** round 10, lens D
**Says:** "Several steps here expect `0`"
**Actually:** exactly one does — Task 6 Step 11. Task 7 Step 8 expects "at least 2"; the Task 1 gate expects `1`.
**Why deferred:** the bullet's advice (`|| true`, read the number not the exit code) is correct and the worker does the same thing either way.

### Global Constraints — "Full suite is ~76 minutes"
**Found:** round 10, lens A
**Says:** "~76 minutes. Run it once, at the end (Task 7)."
**Actually:** Task 7 Step 10 now measures it at 1011s with `-j8`, "closer to 100 minutes" serially. The Global Constraints line still carries the retracted estimate.
**Why deferred:** Step 10 carries the operative command and the measured number; the constraint line is a summary.

### Task 1 Step 5 vs Global Constraints — 64 changes vs 67 lines
**Found:** round 10, lens A
**Says:** Step 5 says `sql/sqitch.plan` "holds 64 changes"; the Global Constraints say the file is 67 lines.
**Actually:** both true — three header/pragma lines.
**Why deferred:** no action depends on reconciling them.

### Task 2 Interfaces — the surviving `else` cited at `:72-80`
**Found:** round 10, lens D
**Says:** the `else` arm is `:72-80`.
**Actually:** its closing `}` is at `:81`, and the citation is a HEAD location, not where it sits after Task 2's own Step 2.
**Why deferred:** describes what survives; no step edits by that range.

### Task 4 "Deliberately untouched" — `PricingPlan.pm:42-47`
**Found:** round 10, lens B
**Says:** the installment validation is `:42-47`.
**Actually:** the second `if` closes at `:48`.
**Why deferred:** the list exists to say *do not touch this*; no range is followed.

### Task 1 harness comment — `fix-clone-schema-identifier-quoting.sql:445-455`
**Found:** round 10, lens B
**Says:** the trigger-copy loop is `:445-455`.
**Actually:** `FROM pg_trigger` is at `:444` and `END LOOP;` at `:457`; the cited range is a mid-loop slice.
**Why deferred:** supports the clone_schema argument; nothing is read at that range.

### Task 1 harness comment — `App/Sqitch/Engine.pm:1084`
**Found:** round 10, lens B
**Says:** `info_literal("  - $name ..")` at `:1084`.
**Actually:** `info_literal(` is at `:1084`, the string at `:1085`.
**Why deferred:** consistent with the `:1037`/`:1038` treatment elsewhere; no action.

### Task 4 Step 7 parenthetical — three `pricing-plan*` files
**Found:** round 10, lens B
**Says:** lists three.
**Actually:** five exist (`-clean-architecture.t` and `-selection-workflow-step.t` too).
**Why deferred:** the operative claim — that `t/dao/pricing-plan.t` does not exist — is true.

### Task 4 Step 1 — the `prove -lv` transcript is a gloss
**Found:** round 10, lens C
**Says:** a five-line transcript.
**Actually:** the real run prints full per-subtest TAP, several stderr diagnostics, and a `Files=1, Tests=4, 15 wallclock secs` footer.
**Why deferred:** the substance (which subtests skip and why) is correct; the step's decision does not turn on a line-for-line diff.

### Task 1 Step 5, Task 6 Step 12 — missing `STRIPE_SECRET_KEY` prefix
**Found:** round 10, lens C
**Says:** `carton exec prove -lv t/database/` with no prefix, unlike every other `prove` line.
**Actually:** harmless — no file under `t/database/` loads a Stripe-key-reading module.
**Why deferred:** the command works as written. Recorded so nobody "fixes" it into inconsistency later.

### Task 6 Step 10 — "If a fourth verify script appears"
**Found:** round 10, lens A
**Says:** a fourth verify script appearing signals incomplete supersession.
**Actually:** the expected list holds two `sql/verify/` entries, so the signal is a *third*.
**Why deferred:** the enumerated list above the sentence is correct and is what the worker checks — and round 10 added an explicit count to that list.

### Coverage Gaps item 3 — "nothing enters the method at all"
**Found:** round 10, lens D
**Says:** after this leg nothing enters `handle_setup_completion`.
**Actually:** true of the test suite, not the code — the `:50` arm survives and a real `setup_intent_id` reaches it. The item's own heading ("loses its last test entry") is the accurate version.
**Why deferred:** it is a coverage note, not an instruction.

---

## Format

```
### <plan section> — <one-line summary>
**Found:** round N, lens X
**Says:** <quoted plan text>
**Actually:** <quoted source>
**Why deferred:** <the action that is unchanged>
```
