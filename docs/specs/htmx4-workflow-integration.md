# HTMX 2.0 Workflow Engine Integration Specification

## Overview

Upgrade the workflow engine to support HTMX-enhanced partial rendering
with progressive enhancement. Every workflow interaction works as plain
HTML (forms, links, redirects) without JavaScript. HTMX 2.0 enhances
the experience by intercepting form submissions and swapping content
fragments without full page reloads. The server detects HTMX requests
via the `HX-Request` header and returns fragments (200) instead of
redirects (302).

**Target HTMX version:** 2.0.x (latest stable). A future spec will
cover the upgrade to HTMX 4 when it ships, including any attribute
renames and the local plugin fork needed to support it.

## Architectural Principles

1. **Progressive enhancement, not dependency.** The plain HTML form
   submission path (POST → 302 redirect → GET → full page) is the
   baseline. HTMX upgrades it. If JS is disabled, broken, or replaced
   by the tenant with React/Alpine/etc., everything still works.

2. **Server framework-agnostic.** The workflow engine checks `HX-Request`
   and responds accordingly. It doesn't know or care what client
   framework is making the request. Tenants can replace HTMX in their
   layout templates via the template editor.

   **Vertical slice:** The template-editor workflow is the first
   target. It already uses stay semantics for every action (list, edit,
   save, revert) and never advances steps. This makes it the simplest
   possible HTMX upgrade and proves the pattern before expanding.

3. **Same template, two modes.** A single template file serves both full
   page (with layout) and fragment (without layout) responses. No
   separate partial templates needed for v1.

4. **URL push on step change only.** When the workflow advances to a new
   step, the browser URL updates via `HX-Push-URL`. Stay actions (same
   step, different view) don't push, keeping history clean.

## Components

### 1. Register Mojolicious::Plugin::HTMX (CPAN)

**Dependency:** Already in `cpanfile` but not registered in `Registry.pm`.

Register the existing CPAN plugin. It bundles HTMX 2.0.x and provides
all the helpers we need out of the box:

- `$c->is_htmx_request` -- detect HTMX requests
- `$c->htmx->req->target` -- which element is the swap target
- `$c->htmx->res->push_url($url)` -- update browser URL
- `$c->htmx->res->retarget($selector)` -- override swap target
- `$c->htmx->res->reswap($style)` -- override swap style
- `$c->htmx->res->trigger(@events)` -- fire client events
- `%= app->htmx->asset` -- template helper to load HTMX script

No fork needed for 2.0.x. A future HTMX 4 upgrade may require a local
fork if the upstream plugin doesn't update in time.

### 2. Workflow Controller Changes

**File:** `lib/Registry/Controller/Workflows.pm`

#### process_workflow_run_step

The main change: after processing a step, check `is_htmx_request` to
determine response format.

**Step advance (non-stay, non-complete):**
```perl
if ( !$run->completed( $dao->db ) ) {
    my ($next) = $run->next_step( $dao->db );

    if ($self->is_htmx_request) {
        # HTMX: render next step as fragment, push URL
        my $next_url = $self->url_for(
            'workflow_step',
            workflow => $workflow_slug,
            run      => $run->id,
            step     => $next->slug,
        );
        $self->htmx->res->push_url($next_url);

        my $template_data = $next->prepare_template_data($dao->db, $run);
        return $self->render(
            template => $workflow_slug . '/' . $next->slug,
            layout   => undef,  # fragment only
            %stash_defaults,
            %$template_data,
        );
    }

    # No JS: traditional redirect
    return $self->redirect_to(...);
}
```

**Stay action:**
```perl
if ($result->{stay}) {
    my $template_data = $result->{template_data} || {};

    if ($self->is_htmx_request) {
        # HTMX: render current step as fragment, no URL push
        return $self->render(
            template => $workflow_slug . '/' . $step_slug,
            layout   => undef,
            %stash_defaults,
            %$template_data,
        );
    }

    # No JS: render full page (current behavior)
    return $self->render(
        template => $workflow_slug . '/' . $step_slug,
        %stash_defaults,
        %$template_data,
    );
}
```

**Completion:**
```perl
if ($self->is_htmx_request) {
    # Return the completion content as a fragment
    # Or trigger a client-side redirect to a confirmation page
    $self->htmx->res->push_url($completion_url);
    return $self->render(
        template => $workflow_slug . '/complete',
        layout   => undef,
    );
}

return $self->render( text => 'DONE', status => 201 );
```

**Continuation (callcc return):**
```perl
if ($self->is_htmx_request) {
    # Render the parent workflow's step as fragment
    $self->htmx->res->push_url($parent_url);
    return $self->render(
        template => $parent_workflow_slug . '/' . $parent_step_slug,
        layout   => undef,
        %parent_template_data,
    );
}

return $self->redirect_to($parent_url);
```

**Validation errors:**
```perl
if ($validation_errors) {
    if ($self->is_htmx_request) {
        # Re-render current step with errors, no URL push
        return $self->render(
            template    => $workflow_slug . '/' . $step_slug,
            layout      => undef,
            errors_json => encode_json($validation_errors),
            %stash_defaults,
        );
    }

    $self->flash(validation_errors => $validation_errors);
    return $self->redirect_to($self->url_for);
}
```

#### get_workflow_run_step (GET handler)

No changes needed for GET requests. The full page with layout renders
as before. HTMX lazy-loading sections (like the admin dashboard's
`hx-trigger="load"` divs) are a template concern, not an engine concern.

#### index (auto-run GET)

No changes needed. The initial page load is always a full page.

### 3. Layout Template Changes

**Files:** All layout templates

Remove per-template CDN script tags for HTMX. Add the plugin's asset
helper to each layout:

```html
<!-- In <head> section of each layout -->
%= app->htmx->asset
```

Layouts to update:
- `templates/layouts/default.html.ep`
- `templates/layouts/workflow.html.ep`
- `templates/layouts/teacher.html.ep`

Remove from individual templates:
- `templates/summer-camp-registration/select-children.html.ep` (line 230)
- `templates/test-classless-css.html.ep` (line 93)
- Any other template that loads HTMX directly

### 4. Workflow Template Pattern

Templates need a consistent swap target. The workflow layout wraps
step content in a div that HTMX targets:

**`templates/layouts/workflow.html.ep`:**
```html
<div id="workflow-content">
    <%= content %>
</div>
```

**Step template forms use HTMX attributes for progressive enhancement:**
```html
<form method="POST" action="<%= $action %>"
      hx-post="<%= $action %>"
      hx-target="#workflow-content"
      hx-swap="innerHTML"
      hx-push-url="false">
    <!-- form fields -->
    <button type="submit">Continue</button>
</form>
```

The `method="POST" action="..."` provides the no-JS fallback. The
`hx-post` provides the HTMX enhancement. Both hit the same server
endpoint. The server decides the response format.

For step-advance forms (where the URL should change):
```html
<form method="POST" action="<%= $action %>"
      hx-post="<%= $action %>"
      hx-target="#workflow-content"
      hx-swap="innerHTML">
    <!-- hx-push-url omitted: server sets it via HX-Push-URL header -->
    <button type="submit">Continue</button>
</form>
```

### 5. HTMX Version Standardization

The codebase currently loads three different HTMX versions:
- `workflow.html.ep`: 1.9.10
- `teacher.html.ep`: 1.8.4
- `test-classless-css.html.ep`: 1.9.9

Replace all CDN script tags with the plugin's asset helper, which
serves a consistent 2.0.x version. No attribute migration is needed
from 1.9.x to 2.0.x for the attributes we currently use (hx-get,
hx-post, hx-target, hx-swap, hx-trigger, hx-vals, hx-confirm,
hx-include).

**HTMX 2.0 behavioral note:** HTMX 2.0 does NOT swap non-2xx
responses by default (unlike the planned HTMX 4 behavior). Validation
errors should use status 200 with error content in the fragment, not
4xx status codes. This matches our current approach.

### 6. App Startup Changes

**File:** `lib/Registry.pm`

Register the CPAN HTMX plugin:
```perl
$self->plugin('Mojolicious::Plugin::HTMX');
```

No additional HTMX configuration needed for 2.0.x. The default
behavior (only swap 2xx responses) is correct for our use case.

## Error Handling

- **Validation errors:** Return 200 with error messages in the fragment.
  HTMX 2.0 only swaps 2xx responses by default, so using 200 for
  validation errors ensures they render. Templates must check both stash
  and flash for errors (stash for HTMX fragments, flash for redirects).

- **HTMX request with server error:** HTMX 2.0 does not swap non-2xx
  responses. The `htmx:responseError` event fires, which can be handled
  via a global listener to show a generic error message.

- **CSRF failure:** The existing `htmx:configRequest` event listener in
  the workflow layout injects `X-CSRF-Token` for all HTMX requests.
  This must be preserved when switching to `%= app->htmx->asset`. If
  CSRF fails, the 403 is not swapped (HTMX 2.0 default), so the page
  stays unchanged. A global `htmx:responseError` handler should show
  "Session expired. Please refresh the page."

- **No JS fallback for lazy-loaded sections:** Any `hx-trigger="load"`
  section should have a `<noscript>` fallback or the data should be
  included in the initial server render. For v1, sections that require
  JS to load are acceptable as long as the core workflow functions
  without them.

## Migration Path

### Phase 1: Vertical Slice (template-editor)
1. Register `Mojolicious::Plugin::HTMX` in `Registry.pm`
2. Update all layout templates to use `%= app->htmx->asset`
3. Remove per-template HTMX CDN script tags (standardize on 2.0.x)
4. Preserve existing CSRF `htmx:configRequest` listener in layouts
5. Verify existing HTMX usage still works (regression tests for
   subdomain validation, admin dashboard lazy loading, domain
   verification, drop request processing, pricing model forms)
6. Add `is_htmx_request` check to workflow controller stay path
7. Add `hx-post` + `hx-target` to template-editor forms
8. Add `#workflow-content` swap target to workflow layout
9. Test: template-editor works with and without JS

### Phase 2: Workflow Step Advance
1. Add `is_htmx_request` checks for step advance (non-stay) path
2. Fragment rendering for advance, completion, continuation
3. URL push via `htmx->res->push_url` on step changes
4. Server always sets `HX-Push-URL` header explicitly (advance=URL,
   stay=false) — no client-side `hx-push-url` attributes needed
5. Add `hx-post` progressive enhancement to registration workflow forms
6. Test: registration workflow works with and without JS

### Phase 3: Remaining Workflows
1. Add `hx-post` progressive enhancement to remaining workflow forms
2. Ensure all forms have working `method="POST" action="..."` fallbacks
3. Test with JS disabled to verify progressive enhancement

### Phase 4: Admin Dashboard Migration
(Separate spec -- depends on this work being complete)

### Future: HTMX 4 Upgrade
(Separate spec -- fork plugin, update attributes, handle behavioral
changes like default swap-on-error)

## Testing Plan

### Perl Controller Tests

**File:** `t/controller/htmx-workflow.t`

1. **Non-HTMX POST advances with 302 redirect**
   - POST without HX-Request header
   - Verify 302 redirect to next step URL

2. **HTMX POST advances with 200 fragment**
   - POST with HX-Request: true header
   - Verify 200 response
   - Verify response has no layout wrapper (no `<html>`, no `<head>`)
   - Verify response has step content
   - Verify HX-Push-URL header set to next step URL

3. **HTMX stay renders fragment without URL push**
   - POST with HX-Request: true to a stay action
   - Verify 200 response with fragment
   - Verify no HX-Push-URL header

4. **HTMX validation error re-renders with errors**
   - POST with HX-Request: true and invalid data
   - Verify 200 response with error messages in fragment

5. **HTMX completion renders fragment**
   - POST final step with HX-Request: true
   - Verify 200 with completion content (not "DONE" text)

6. **HTMX callcc return renders parent fragment**
   - Complete child workflow with HX-Request: true
   - Verify parent workflow step rendered as fragment

### Regression Tests for Existing HTMX

**File:** `t/controller/htmx-regression.t`

Verify existing HTMX usage still works after version standardization:

1. **Admin dashboard lazy loading** -- `hx-trigger="load"` sections
   return fragments (no layout wrapper)
2. **Subdomain validation** -- `hx-trigger="keyup changed delay:500ms"`
   returns validation result
3. **Domain verification** -- `hx-post` with `hx-swap="outerHTML"`
4. **Drop request processing** -- `hx-post` with `hx-vals` and
   `hx-confirm`
5. **Pricing model dynamic forms** -- `hx-trigger="change"` returns
   form sections

### Playwright Browser Tests

**File:** `t/playwright/htmx-progressive-enhancement.spec.js`

1. **Workflow works without JS**
   - Disable JS in browser
   - Complete a registration workflow via form submissions
   - Verify each step loads as full page

2. **Workflow enhanced with HTMX**
   - Enable JS (default)
   - Complete same workflow
   - Verify no full page reloads (check network for 200 vs 302)
   - Verify URL updates on step changes
   - Verify content swaps in #workflow-content

3. **Stay action swaps without URL change**
   - Template editor: edit a template
   - Verify content updates without URL change
   - Verify browser back button doesn't cycle through edits

4. **Error display in fragment**
   - Submit invalid data (short reason in drop request)
   - Verify error message appears in content area
   - Verify page structure intact (header/nav not replaced)

## Dependencies

- `Mojolicious::Plugin::HTMX` from CPAN (already in cpanfile)
- Existing workflow engine with stay semantics
- Existing template infrastructure (DB-first rendering, layouts)

## Notes

- The HTMX script is loaded in layout templates, which are editable
  by tenants via the template editor. A tenant can replace HTMX with
  any client framework. The server-side behavior is unchanged -- it
  checks `HX-Request` and falls back to plain HTML.

- DB-first template rendering and HTMX fragment rendering compose
  naturally. DB templates render via `inline =>` in Controller::render,
  and `layout => undef` works the same for both DB and filesystem
  templates. No special handling needed.

- Templates that use `% extends 'layouts/workflow'` override the
  controller's layout setting. For HTMX fragments, the controller must
  clear the `extends` directive. The simplest approach: set a stash
  flag (`_htmx_fragment => 1`) that the layout template checks, or
  handle this in the Controller::render override.

- HTMX 4 features like `innerMorph` swap style (preserving form state
  during re-renders) are future enhancements for the HTMX 4 upgrade.
