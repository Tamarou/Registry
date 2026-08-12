# Leg 1 Plan — Deferred Prose Findings

Inaccuracies found in `2026-08-09-priceops-leg-1-safe-deletions.md` that do **not** change what an executing worker does, and are therefore left in the plan rather than corrected there.

The reason is measured. Across review rounds 6-9 the plan accumulated 78 verified findings, and the share introduced by the previous round's own corrections rose 3 → 8 → 9. Rewriting explanatory argument was generating defects at roughly the rate it removed them. From round 10 the plan takes only corrections that change an action; everything else lands here.

**What belongs here:** wrong or stale citations that support an argument rather than direct a step; counts in narrative; claims in commit-message bodies; Coverage Gaps and Self-Review wording; Deviation descriptions; anything where the worker's next keystroke is the same either way.

**What does not:** line numbers and ranges a step follows, step ordering, code, SQL, commands, gate patterns and match counts, `git add` file lists, safety constraints. Those are corrected in the plan.

---

## Open

_None recorded yet. Round 10 is the first round under the freeze._

---

## Format

```
### <plan line at time of finding> — <one-line summary>
**Found:** round N, lens X
**Says:** <quoted plan text>
**Actually:** <quoted source>
**Why deferred:** <the action that is unchanged>
```
