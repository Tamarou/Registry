# Template ownership and revisions

**Status:** design, not yet implemented
**Motivating issue:** #352 — platform template changes have no deploy path
**Prior art read for this:** `jj-vcs/jj@a4a61b3` (v0.45.1), object model and first-class conflicts

## Why this document exists

Three separate defects share one cause, and fixing any of them badly makes the other two worse.

1. **A platform template change cannot be deployed.** `import_from_file` is insert-only, so the row shipped in March is the row production still renders. The fixes merged in #346 are unreachable. This is a go-to-market blocker (#352).
2. **A tenant edit destroys what it replaces.** `TemplateEditor` writes content with an `UPDATE`. There is no previous version to go back to.
3. **Every tenant forks at provision.** `copy_workflow` copies template content into the tenant schema when the tenant is created, so a platform improvement reaches nobody who already exists.

The common cause is that **a template has exactly one row and that row is both its identity and its content.** There is nowhere to put a second version, so "update the platform copy" and "keep the tenant's copy" are the same write, and the code resolves the conflict by refusing to write at all.

What follows separates identity from content, makes content history append-only, and gives tenants a way to take a platform change without losing their own — modelled on jj, because jj is a version control system whose entire design premise is that a merge which does not resolve must not block anything.

---

## 1. What is actually there today

### 1.1 The schema

`sql/deploy/workflows.sql:19`:

```sql
CREATE TABLE IF NOT EXISTS templates (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    name text UNIQUE NOT NULL,
    slug text UNIQUE NOT NULL,
    content text NOT NULL,
    metadata jsonb NULL,
    notes text NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);
```

No `tenant_id`. Isolation is by schema: `registry.templates` is the platform set, `<slug>.templates` is each tenant's. `workflow_steps.template_id` references `templates(id)`, so **`templates.id` is already a stable identity that survives content edits.** That turns out to matter — see §3.3.

### 1.2 The four paths that touch a template

| Path | Code | Behaviour |
|---|---|---|
| Platform deploy | `Template.pm:24` `import_from_file` | insert-only; returns the existing row untouched |
| Tenant provision | `schema-based-multitennancy.sql:143-160` `copy_workflow` | copies `name, slug, content, metadata` into the tenant schema, per workflow |
| Tenant edit | `TemplateEditor.pm:36` | `UPDATE templates SET content = ?, updated_at = now() WHERE id = ?` |
| Tenant revert | `TemplateEditor.pm:65-77` | `SELECT content FROM registry.templates WHERE name = ?`, then `UPDATE` the tenant row with it |
| Render | `DBTemplates.pm` `$c_db_lookup` | `find(Template => { name => $db_name })->content`, per render, against the request's tenant DAO |

Three things to note, because they contradict assumptions that are easy to make.

**Cross-schema reads already happen, deliberately.** The revert path at `TemplateEditor.pm:65` reads `registry.templates` from inside a tenant request. Adding more of them is not a new departure; it is an existing, commented-on pattern.

**Revert matches on `name`, not on identity.** `name` is derived from the file path by `import_from_file`. Renaming a template file therefore silently orphans every tenant's revert — it stops finding a platform row and reverts to nothing. This is the concrete cost of having no stable cross-schema reference, and it is what the URI scheme in §3.5 exists to fix.

**Revert is a content copy, not a pointer move.** After reverting there is no record that the tenant ever customised anything. Revert is currently indistinguishable from never having edited.

### 1.3 The guard in `import_from_file` guards nothing on the path that runs

```perl
# If it exists, leave it alone -- tenants may have customized it
if ($template) {
    return $template;
}
```

The comment describes a real fear, but not one that applies where the code runs. `import_templates` (`Registry.pm:794`) hardcodes `load('registry')`, and `docker-entrypoint.sh` runs `./registry template import registry`. Both operate on the **registry** schema. A tenant's customisation lives in the tenant's schema. **A write to `registry.templates` cannot clobber it.**

The guard is not dead — `Registry::Command::template` accepts a schema argument, so a human can run `./registry template <tenant> import` and the guard is doing real work there. It is misplaced, not unnecessary. The condition it should test is *ownership*, not *existence*.

That single observation is the whole fix for #352, and it needs none of the rest of this document. See §6.1.

---

## 2. What we take from jj, and what we leave

jj's model is two independent content-addressed graphs: commits (never mutated, never deleted) and operations (an append-only log where every mutable pointer in the repo lives inside a versioned `View`). Everything else — change-id lookup, descendant sets, visibility — is a derived index that can be dropped and rebuilt.

Most of jj's line count exists because jj lives on a filesystem and must interoperate with Git. We have one blob per template and a relational database. The parts that survive the translation:

| jj mechanism | Verdict | Why |
|---|---|---|
| `Merge<T>`: odd-length array alternating positive/negative terms | **Take** | One array column plus a `CHECK` gives first-class conflicts. §3.2, §4. |
| Terms are whole snapshots, not diffs | **Take** | Templates are 5-50KB. Storing diffs means reimplementing the algebra over patches, which is where homegrown VCSs die. |
| `flatten()` + `simplify()` | **Take** | These two functions are the value: repeated platform updates onto an unresolved fork collapse instead of nesting. §4.2. |
| Conflict labels parallel to the merge terms | **Take** | "the new platform version" / "your version" / "what you started from" is worth far more to a tenant than three opaque HTML blobs. |
| Stable change identity, preserved across every rewrite | **Take** | `templates.id` already is this. §3.3. |
| Divergence is reported, not blocked; no uniqueness constraint on it | **Take** | A platform deploy must never fail because one tenant's fork conflicts. |
| Append-only history; "undo" is an insert, never an update | **Take** | §3.4, §5. |
| Conflicts allowed internally, gated at the publish boundary | **Take** | A tenant may *save* a conflicted template; the renderer refuses to *serve* one. §5.5. |
| Content-addressed ids | **Take, for blobs only** | A hash names content. It cannot name lineage. §3.3. |
| Per-path conflict derivation: a term is a *map* of names to content, and conflicts are computed per name | **Take, at depth 1** | Not filesystem machinery. A template has content *and* metadata; a curriculum has five named fields. Merging whole records conflicts on every co-edit. §4.4, §9. |
| Recursive trees, `.jjconflict-*` dirs, copy tracking, the working copy, `RepoPath` | **Leave** | That *is* filesystem machinery. Our maps are one level deep and never nest. |
| Operation DAG with merges, op-heads-as-filenames, lock-free concurrency | **Leave** | That subsystem exists to get atomicity on NFS. We have `BEGIN`/`COMMIT`. Our log is linear. |
| A full `View` object holding every mutable pointer | **Leave for now, with a caveat** | §7. |
| ID-prefix trie, the undo-stack description-string hack | **Leave** | `LIKE 'abc%'`; and a column instead of a parsed string. |

One deliberate divergence from jj. jj's forward rewrite mapping is in-memory and dies with the transaction. Ours cannot be: rebasing every tenant's fork after a platform deploy is a background job, not a request. §5.4.

---

## 3. The model

### 3.1 Blobs — content, addressed by its hash

```sql
CREATE TABLE document_blobs (
    id         text PRIMARY KEY,          -- 'sha256:' || encode(digest(content,'sha256'),'hex')
    content    text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
```

Created in **both** the registry schema and every tenant schema. A blob is written into the schema of the revision that first referenced it: platform content lands in `registry.document_blobs`, tenant-authored content in `<slug>.document_blobs`.

This resolves the shared-versus-per-schema question in the way that matches the isolation model we already have. Platform content — which every tenant shares and which is the bulk of the bytes — is stored once. Tenant-authored content never leaves the tenant schema, so `DROP SCHEMA <slug> CASCADE` still removes everything a tenant wrote. Resolution is: look in the current schema, then in `registry`.

Insert is `ON CONFLICT (id) DO NOTHING`. Identical content written twice is one row, which is exactly what happens today when forty tenants provision from the same platform template and get forty copies of the same bytes.

The table is named for documents rather than templates deliberately. A blob is bytes and a hash; nothing about it is template-specific, and curriculum will want the same store (§9). Making it generic costs nothing now and is a migration later.

### 3.2 Revisions — append-only, and possibly conflicted

```sql
CREATE TABLE template_revisions (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    template_id   uuid NOT NULL REFERENCES templates(id),
    content_ids   text[] NOT NULL CHECK (array_length(content_ids, 1) % 2 = 1),
    labels        text[],
    parent_id     uuid REFERENCES template_revisions(id),
    forked_from   text,          -- URI. No FK. See §3.5.
    operation_id  uuid NOT NULL,
    author_id     uuid REFERENCES users(id),
    note          text,
    created_at    timestamptz NOT NULL DEFAULT now()
);
```

`content_ids` is jj's `Merge<T>`, and it is the load-bearing choice in this design. An odd-length array whose terms alternate positive, negative, positive: index 0 is a snapshot, and each subsequent pair `(remove, add)` is a diff to apply to it. `['sha256:abc']` is a resolved revision — one snapshot, nothing to reconcile. `[P2, P1, T1]` reads as "platform's new version, plus whatever the tenant changed relative to the version they started from".

Each term is a manifest hash, not a document hash — see §4.4 for why that indirection exists and what it costs.

`labels` runs parallel to it, one human string per term, and must have the same length. Resolved revisions carry no labels.

`metadata` is **not** a column here. It is a part inside the manifest (§4.4), merged like any other, because a metadata-only edit and a content-only edit are not a disagreement. Nothing on the render path reads template metadata today; confirm that during migration.

`parent_id` is the previous revision of this same template. It is what makes per-template history a walk rather than a timestamp sort, and it is nullable only for a template's first revision.

`operation_id` groups every revision written by one action. A `template import` writes one per changed template, all sharing an id, so "undo that deploy" has something to select on. §5.6.

The table is **`INSERT`-only, forever.** No `UPDATE`, no `DELETE`. Reverting is an insert. Resolving a conflict is an insert. That is what makes history trustworthy and it is what lets a pruning story be added later rather than designed now.

### 3.3 Templates — identity, and two pointers

```sql
ALTER TABLE templates
    DROP COLUMN content,
    ADD COLUMN owner text NOT NULL DEFAULT 'platform'
        CHECK (owner IN ('platform', 'tenant')),
    ADD COLUMN head_revision_id    uuid REFERENCES template_revisions(id),
    ADD COLUMN current_revision_id uuid REFERENCES template_revisions(id);
```

`templates.id` is the change identity, in jj's sense: stable across every edit, never regenerated, carried forward when a revision is written. We get this for free — `workflow_steps.template_id` already depends on it being stable, so the existing schema has been maintaining jj's change-id invariant without a name for it.

`owner` is the marker that makes #352 fixable. `platform` rows are managed by `template import` and are never edited in place by a tenant. `tenant` rows are the tenant's, and import must never touch them. **No uniqueness constraint anywhere ties a tenant row to the platform row it forked from** — divergence is a state we report, not one we prevent.

Two pointers, because "what the tenant is working on" and "what the public sees" are different questions:

- **`head_revision_id`** — the newest revision. May be conflicted. This is what the editor opens.
- **`current_revision_id`** — what the renderer serves. **Must reference a resolved revision** (`array_length(content_ids,1) = 1`). Moving it is a publish.

Both are FK'd because both are within-schema, on the render path, and a dangling one is a blank page.

`head_revision_id` is strictly a cache: it is derivable as the newest revision of the template, because every operation appends. Keep it anyway — `DBTemplates` does a template lookup per render and the extra index scan is not free. State the invariant in the migration's `verify` so a drifted cache fails a deploy rather than a page load.

`current_revision_id` is not derivable. It is real state and moving it is a real decision, which is why §5.6 records the moves.

### 3.4 What `notes`, `updated_at` and the rest become

`content` leaves `templates` entirely — it lives only in blobs, reachable only through a revision. There is one copy of the bytes and one place to look for them.

`updated_at` on `templates` stops being meaningful and should be read from `head_revision_id`'s `created_at`. Leave the column; do not maintain it.

`notes` stays on the identity row (it describes the template, not a version). `note` on a revision is the per-change message — what jj calls a description, what a commit message is.

### 3.5 URIs — the cross-schema reference

A reference that crosses a schema boundary, or one day a system boundary, is a URI. A reference within a schema is a foreign key. That is the whole rule.

```
registry://<authority>/template/<template-uuid>
registry://<authority>/template/<template-uuid>@<revision-uuid>
registry://<authority>/blob/sha256:<hex>
```

`<authority>` is the schema: `registry` for the platform, the tenant slug otherwise. Resolution maps authority to schema, path to table and primary key. One resolver function, and the schema-mapping is the only part that has to know about multi-tenancy.

**What is addressable is chosen deliberately.** `template_id` is stable across every edit. A blob hash is stable by construction. `name` and `slug` are neither — they are derived from file paths and can be changed. Today's revert matches on `name` and breaks silently when a file is renamed (§1.2); a URI built on `template_id` cannot.

**Dereferenceable** means a URI in hand is enough to fetch the thing, with no other context — the resolver takes a URI and a database handle and returns content or `undef`. Nothing in the URI depends on which tenant is asking.

**No FK on `forked_from`.** It crosses a schema boundary, so Postgres could not enforce it anyway, but the more important reason is that it *should* degrade. `forked_from` is read at merge time, to answer "what did this tenant start from". If the platform revision it names has been pruned, the correct behaviour is to skip the three-way merge and offer the tenant a straight choice between two versions — not to fail. A foreign key would turn a recoverable degradation into a blocked deploy.

The HTTP form — `https://<host>/.well-known/registry/blob/sha256:<hex>` — is what makes these addressable between systems. It is not needed for anything on the roadmap and should not be built until something wants it. The scheme is designed so it can be added without changing any stored value.

---

## 4. The merge algebra

Three functions over `content_ids`. They are small, and porting them faithfully matters more than porting them cleverly.

### 4.1 `resolve_trivial` and `simplify`

`resolve_trivial` counts: positive terms `+1`, negative terms `-1`. If exactly one distinct value survives with a net count of 1, that is the answer and the merge is resolved.

`simplify` cancels: find a positive term equal to some negative term and delete both. Implement it as an **index permutation** rather than a rewrite — keep a mapping from simplified position back to original position — so an edit made against a simplified two-sided view can be mapped back onto a revision that is internally four terms. jj does this for exactly this reason and it is not optional if tenants will ever edit a conflicted template by hand.

### 4.2 `flatten`, and why conflicts do not nest

This is the property that justifies the whole representation, so here it is worked out.

A tenant forked from platform revision `P1` and edited it to `T1`. Platform ships `P2`. We rebase: `merge(P2, P1, T1)` → `[P2, P1, T1]`. Suppose it does not resolve. The tenant leaves it.

Platform then ships `P3`. Rebase again: `merge(P3, P2, current)` where `current` is itself `[P2, P1, T1]`. Flattening splices the inner merge into the outer one:

```
[P3, P2, [P2, P1, T1]]  →  flatten  →  [P3, P2, P2, P1, T1]
```

Five terms. Now simplify: the positive `P2` at index 2 cancels the negative `P2` at index 1.

```
[P3, P2, P2, P1, T1]  →  simplify  →  [P3, P1, T1]
```

Three terms, and no trace of `P2`. The tenant's unresolved conflict against the previous platform version did not compound; it moved. **A tenant who ignores conflicts for a year is in the same shape as one who ignored them for a week.** Nothing in the code special-cases this — it falls out of cancellation, which is why the algebra is worth having rather than an ad-hoc "store the base and the two sides".

### 4.3 The same-change rule

jj resolves `A + (A − B)` to `A` — if all sides made the same change, take it. jj's own documentation is candid that this breaks the algebra (rebasing away and back can lose changes) and that they keep it because it is what users expect.

**Take the rule.** Two tenants who make the same edit the platform later makes should see it resolve, not conflict. Record the choice here so that when it eventually produces a surprising result, the cause is documented rather than rediscovered.

### 4.4 Granularity: what a term is a hash *of*

A term in `content_ids` is the hash of a **manifest** — a canonical JSON map from part name to blob hash — not of the document itself. Merging is then per part, exactly as jj derives a per-path conflict by looking up that path in each of its tree terms. One level deep, never nested.

For a template the manifest has two entries, `content` and `metadata`. For a curriculum it has one per named field (§9). The degenerate one-entry case is a manifest too, so there is a single code path.

This is not generality for its own sake — merging whole records makes any co-edit a conflict. A tenant who changed a template's metadata conflicts with a platform change to its content, and they have not actually disagreed about anything. At curriculum's five-plus fields that failure mode stops being an edge case and becomes the normal outcome.

Two consequences.

**The render path gains an indirection.** `current_revision_id` → manifest → the `content` blob. `DBTemplates` does a lookup per render, so this must resolve in one query — a join through the manifest, not a second round trip. Denormalising the served content back onto `templates` is available if the join measures badly; do not do it pre-emptively.

**Manifests are normalised before storage.** jj builds each side of a conflicted tree so the sides agree everywhere except where they genuinely conflict, which is what keeps "list the conflicted paths" cheap. Do the same: a conflicted revision's manifest terms carry the *resolved* parts identically in every term, and differ only where the merge actually failed. Otherwise "which fields conflict" is a comparison across N manifests on every editor load.

Line-level merging inside the document — producing a partially-merged document with markers around only the hunks that actually conflict — is a strictly better tenant experience and is a separate piece of work. It changes nothing in the schema. If it is built, two rules from jj are not improvisable:

- **Marker length must be chosen from the content** (minimum 7, widening by 4 while the content contains a run that long). Our templates are HTML with embedded Perl. A literal `<<<<<<<` inside a template is entirely plausible, and a fixed marker length will eventually corrupt a tenant's page.
- **Byte-identical re-materialisation is a no-op, and markers removed means resolved.** Without the first, opening and saving a conflicted template partially resolves it. The second is what makes "delete the markers" the resolution gesture, with no separate button.

Both require storing the marker length and the simplified arity alongside the editor draft — a draft row, not a revision row.

Line-level merging applies within one part. It composes with the manifest rather than replacing it.

---

## 5. Operations

### 5.1 Platform deploy — `template import`

For each file, compute the content hash. If the platform template's current blob already equals it, do nothing. Otherwise insert the blob, insert a resolved revision (`content_ids = [hash]`, `parent_id` = the previous head), and move both pointers.

Every revision in one import shares an `operation_id`.

Import touches rows with `owner = 'platform'` only. This is the ownership check replacing the existence check from §1.3.

### 5.2 Tenant provision

`copy_workflow` stops copying content. A tenant gets a `templates` row with `owner = 'tenant'` and `current_revision_id` pointing at a revision whose single term is **the platform blob's hash** and whose `forked_from` is the platform revision's URI. No bytes are copied; the tenant's revision references the blob in `registry.document_blobs`.

A tenant who never customises anything therefore has no content of their own at all, and picking up a platform update for them is a pointer move.

### 5.3 Tenant edit and revert

**Edit:** insert a blob, insert a revision with `parent_id` = current head, move both pointers. `TemplateEditor`'s destructive `UPDATE` goes away.

**Revert to the previous version:** insert a new revision whose `content_ids` equal the parent's. The undo is itself in the history and is itself undoable. Never move a pointer backwards to an old revision — that is the one thing jj's design forbids, and the reason is that a pointer move leaves no record of having happened.

**Revert to stock:** insert a revision whose single term is the current platform blob, `forked_from` set to the platform revision. Note the difference from today: the tenant's own history survives, so "actually, put my version back" is still available. Today it is not.

### 5.4 Taking a platform update — the rebase

When the platform publishes a new revision of template X, every tenant template whose `forked_from` names an older revision of X is a candidate. For each, the new content is `merge(new_platform, old_platform, tenant_current)`, flattened and simplified.

Resolved: insert a resolved revision, move both pointers. The tenant sees the update.

Not resolved: insert a conflicted revision with labels, move `head_revision_id`, **leave `current_revision_id` where it is.** The tenant keeps serving their working page and gets a notification. Nothing about the platform deploy failed.

**This is a background job, not a request.** jj keeps its rewrite mapping in memory because it is a single-process CLI; we cannot. The forward mapping is a durable queue:

```sql
CREATE TABLE registry.template_rebase_queue (
    id                 bigserial PRIMARY KEY,
    tenant_schema      text NOT NULL,
    template_id        uuid NOT NULL,
    old_revision_uri   text NOT NULL,
    new_revision_uri   text NOT NULL,
    kind               text NOT NULL CHECK (kind IN ('rewritten','divergent','abandoned')),
    status             text NOT NULL DEFAULT 'pending',
    operation_id       uuid NOT NULL,
    created_at         timestamptz NOT NULL DEFAULT now()
);
```

`kind` is jj's three-variant rewrite enum, and all three cases are real here:

- **`rewritten`** — the platform revised a template. Rebase descendants onto it.
- **`divergent`** — the platform shipped two variants, or a fork-of-a-fork was detected. **Do not rebase.** Report it and let a human choose. jj suppresses auto-rebase in exactly this case because there is no principled answer to which side to follow.
- **`abandoned`** — the platform retired a template. Descendants reparent onto its parent; the tenant keeps what they have.

Drain it with Minion, which already runs.

### 5.5 The publish gate

The renderer serves `current_revision_id`. The FK plus the "must be resolved" rule means it cannot be handed a conflicted revision. Enforce it where the pointer moves, not in the renderer:

```sql
-- moving current_revision_id to a conflicted revision is refused
```

as a trigger or a check in the publishing function. This is jj's boundary rule — conflicts are legal everywhere internally, gated only where they would reach someone who cannot deal with them — and it is the reason the whole thing is safe: a tenant can sit on an unresolved merge indefinitely without their site breaking.

### 5.6 The operation log, minimal

```sql
CREATE TABLE template_publications (
    id            bigserial PRIMARY KEY,
    operation_id  uuid NOT NULL,
    template_id   uuid NOT NULL REFERENCES templates(id),
    revision_id   uuid NOT NULL REFERENCES template_revisions(id),
    published_by  uuid REFERENCES users(id),
    published_at  timestamptz NOT NULL DEFAULT now()
);
```

Append-only, one row per move of `current_revision_id`. This is the smallest thing that answers "what did the 04:00 deploy change" and "put it all back" — select the rows with that `operation_id`, and for each, publish the revision that was current before it.

It is deliberately not jj's `View`. jj versions every pointer in the repo as one object because its operations span bookmarks, heads and working copies across workspaces. Ours span one column. A `View` table is the right endpoint if template operations ever need point-in-time reads consistent across many templates at once; `operation_id` is the same key, so it can be added later without rewriting what exists.

What cannot be added later is the history itself. That is why this table is in v1 and not deferred.

---

## 6. Sequencing

### 6.1 First, and independently: fix #352

`import_from_file` tests existence where it means to test ownership. Adding `owner` to `templates` and changing the guard to "never touch a tenant-owned row; always reconcile a platform-owned one" fixes the production defect — three tiers rendering with no rate, and the anchors not greyed — and requires none of §3 through §5.

It is a migration adding one column with a default plus a few lines in `Template.pm`. Ship it on its own.

The interim production `UPDATE` to restore the rate on the pricing card is still worth doing before this lands, because it is a live money-path page.

### 6.2 Then: blobs and revisions

Migrate `templates.content` into `document_blobs` and a single resolved revision per existing row, in both the registry schema and every tenant schema. The migration is mechanical and the row counts are small. Point `head_revision_id` and `current_revision_id` at it, and drop `content`.

Rewrite `TemplateEditor`'s save as an insert and its revert as an insert. At this point tenants have history and the name-matched revert is gone.

### 6.3 Then: the merge

`Merge` in Perl — `flatten`, `simplify`, `resolve_trivial` — with the index-permutation form of `simplify`. This is the piece that needs real tests: the arity invariant, the cancellation identity in §4.2, the same-change rule, and the round-trip through a simplified view.

Then the rebase queue and the Minion job, then the tenant-facing pick-and-merge UI.

### 6.4 Then, and only if wanted

`copy_workflow` stops copying content (§5.2). Line-level merging (§4.4). The HTTP dereference form (§3.5).

---

## 7. Deliberately not doing

**A full `View` table.** §5.6 explains the tradeoff and the upgrade path.

**Pruning.** Revisions and blobs are append-only forever. The corpus is small — a few hundred templates times a handful of revisions — and append-only is what makes everything above trustworthy. Write the reachability query when writing the schema, so that the shape of "what is still referenced" is known, but do not run anything.

**Conflicted pointers.** jj's bookmarks are themselves merges, so two instances can disagree about where a bookmark points. That is only needed for peer-to-peer sync between Registry instances, which is not on the roadmap. It is genuinely expensive to retrofit — a scalar FK becoming an array — so it is worth naming: if cross-instance sync ever becomes real, `current_revision_id` is the column that has to change shape.

**Content-hashing revision ids.** Blobs are hashed because content addressing is what makes them shareable and dedupable. Revision ids are UUIDs because a revision is an identity with lineage, and a hash of content cannot express lineage — two tenants arriving at identical content have not made the same change.

---

## 8. Curriculum

This model is not template-specific, and curriculum is the second user. Recording that here so the first implementation does not foreclose it.

### 8.1 Curriculum is already the same shape

`sql/deploy/events-and-sessions.sql:26` — curriculum is `projects`:

```sql
CREATE TABLE IF NOT EXISTS projects (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    name text UNIQUE NOT NULL,
    slug text UNIQUE NOT NULL,
    metadata jsonb NULL,
    notes text NULL,
    ...
);
```

That is `templates` with `content` removed and the content living in `metadata` — learning objectives, materials needed, skills developed (`CurriculumDetails.pm`). It forks at provision the same way, and harder: `events-and-sessions.sql:79` does `CREATE TABLE %I.projects AS TABLE registry.projects`, a whole-table copy rather than the per-workflow copy `copy_workflow` does for templates.

So all three defects in §1 are curriculum's defects too, and the identity/revisions/blobs split applies unchanged.

### 8.2 What transfers, and what does not

Unchanged: `document_blobs`, the revision table's shape, the `Merge` algebra, append-only history, the publish gate, the URI scheme.

**Do not build one polymorphic `documents` table.** `templates` and `projects` keep their own identity rows, because identity is domain-specific and `workflow_steps.template_id` already depends on `templates(id)`. What is shared is the blob store, the `Merge` module (pure functions over arrays — it never learns what a template is), and the rebase queue with a kind column. A per-kind revisions table is a few lines of duplicated DDL; a polymorphic identity table costs a broken foreign key.

**The manifest is what curriculum forces.** A curriculum has five-plus independently edited fields. Merging whole records means any co-edit is a conflict, which at that field count is the normal outcome rather than an edge case. §4.4 is written the way it is because of curriculum; templates ship the two-entry case.

### 8.3 The marketplace changes who publishes

#33 is a curriculum marketplace — a tenant sells curriculum to other tenants. Two consequences.

**The source is a peer, not the platform.** `forked_from` is already a URI with an authority, so `registry://jordans-studio/curriculum/<uuid>@<rev>` needs nothing new. The rebase queue in §5.4 is written with `tenant_schema` and platform-shaped URIs; generalise it to a source URI plus a target schema. `owner` stays a two-value enum — a purchased curriculum is owned by the buying tenant.

**Append-only collides with licensing.** A buyer's revision references blobs that were first written in the seller's schema. Append-only forever means an expired or revoked licence does not remove the buyer's access to the content, because the blob is still there and still addressed by its hash.

That is a policy question, not a schema one, and the answer is the same shape as §5.5: **gate at the boundary, not in the store.** A licence check belongs where curriculum is served and where a revision is published, not as a deletion. Deleting blobs to enforce a licence would break every other buyer who deduped onto the same hash.

Worth deciding before the marketplace ships, not before templates do.

---

## 9. Open questions

**Do tenants rename templates?** The URI scheme is built on `template_id` specifically so that renaming is safe. But `name` is `UNIQUE NOT NULL` and `DBTemplates` looks up by name, gating that lookup on an index built from the registry schema. A tenant-originated name fails the gate and falls through to the filesystem, silently. Filed as **#353**; it is a prerequisite for the marketplace (§8.3) rather than for anything here.

**Should a tenant be able to see the platform's history?** Reverting to stock needs the platform's *current* revision. Offering "go back to the platform version from before the last update" needs its history, and that is a broader cross-schema read than anything currently done. Defer until a tenant asks.

**What happens to a conflicted template when the tenant is provisioned a new workflow that uses it?** `copy_workflow` operates per workflow, so the same template can be reached twice. With content in a shared blob and identity in `templates`, the second copy should find the existing row rather than insert a second one — but the current code inserts unconditionally. Check this during §6.2.
