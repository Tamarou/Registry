# ABOUTME: Architecture Decision Record for the server-side allowlist of workflow step classes.
# ABOUTME: Records why a step's class must be a shipped class and where that is enforced.

# ADR 002: Workflow Step Classes Come from a Server-Side Allowlist

**Status:** Accepted

**Date:** 2026-11-22

---

## Context

A workflow step names a Perl class in `workflow_steps.class`, and that class's
`process` runs when a visitor reaches the step. Before this decision the column
was trusted twice over:

- **At creation**, `Registry::DAO::WorkflowSteps::CreateWorkflow` stored the
  `class` straight from the submitted `workflow-creation` form. Every tenant
  holds `workflow-creation` for its `admin` and `staff` roles, so a tenant's
  staff member could make the shared process store any class name.
- **At load**, `Registry::DAO::WorkflowStep->find` loaded the stored class with
  a string `eval "require $class"`. A string eval runs its argument as Perl, so
  the column was effectively source code: a stored value of
  `Registry::DAO::WorkflowStep; $main::PWNED = 1` set `$main::PWNED`
  (`t/security/workflow-step-class-allowlist.t` demonstrated this before the
  fix).

The PriceOps model (`docs/superpowers/specs/2026-11-21-priceops-model-design.md`,
"How PriceOps is driven") requires that a tenant compose allowed steps and never
name code.

---

## Decision

A workflow step's class is allowed only if it is `Registry::DAO::WorkflowStep`
itself or a module shipped under the application's own
`lib/Registry/DAO/WorkflowSteps/`. `Registry::WorkflowStepClasses::is_allowed`
is the single check.

### What counts as shipped

- The directory is located from the allowlist module's own file and made
  absolute once, when the module loads. It is never searched for through
  `@INC`, and it does not follow the process's working directory.
- The set of class names is read from that directory tree once at load
  (including nested directories such as `AttendanceCheck/`). A name is compared
  against that set exactly, so the match is exact even on a case-insensitive
  filesystem.
- A name must first match
  `\ARegistry::DAO::WorkflowSteps::[A-Z][A-Za-z0-9]*(?:::[A-Z][A-Za-z0-9]*)*\z`.
  It is anchored with `\A` and `\z`, not `^` and `$`, because `$` matches before
  a trailing newline.

### Where it is enforced

- **Creation:** `WorkflowStep->create` refuses a class outside the allowlist,
  so every path that writes a step is covered: `Workflow->add_step`,
  `Workflow->from_yaml`, the workflow-creation workflow and the controller's
  auto-created steps. `CreateWorkflow` checks every submitted step before it
  writes anything, so one refused step leaves no workflow and none of the steps
  before it.
- **Update:** `WorkflowStep->update` refuses the same, so update is not a way
  round the creation check.
- **Load:** `WorkflowStep->find` checks the stored class against the allowlist
  before loading anything, loads an allowed class with
  `Module::Runtime::require_module` (never a string eval), and refuses a loaded
  class that is not a `Registry::DAO::WorkflowStep` before its constructor runs.
  A stored row is not trusted on any connection: rows written before the
  creation check, written around the DAO, or planted in a tenant schema's own
  `workflow_steps` are all refused here.
- **Starting a workflow:** a workflow whose first step is refused cannot be
  started, and leaves no run behind, both through
  `Registry::WorkflowProcessor->new_run` and through the HTTP start route (whose
  repair fallback re-raises a refusal rather than building a run around it).

The caller sees the refusal as an exception reading
`'<class>' is not an allowed workflow step class` (or
`<class> is not a workflow step`).

---

## Consequences

- A new kind of step behaviour is a new shipped step class under
  `lib/Registry/DAO/WorkflowSteps/` and a deploy. New offers, prices and
  policies are data and need neither.
- Test-only step classes in `t/lib` cannot be stored as a step's class. A test
  that needs a custom step builds the object directly
  (`t/controller/workflow-run-isolation.t`).
- The HTTP start route recognises a refusal by its message text. A typed
  exception would be sturdier; that is noted as debt, not done.

---

## Alternatives Considered

- **A hand-kept list of allowed classes.** It would need an edit for every step
  class that steps 4, 5 and 7 add, and would drift from the tree. A tenant
  cannot add files to the shipped tree, so deriving the set from it is as tight
  as a list.
- **Searching `@INC` for the class file.** `@INC` includes `t/lib` under test and
  whatever a deployment adds; a step file placed on it must not become allowed.
- **Checking only at creation.** Rows that predate the check, rows written
  around the DAO and tenant-schema copies would still be loaded, and the string
  eval would still run them.
