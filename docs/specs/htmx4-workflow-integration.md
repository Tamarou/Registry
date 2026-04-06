# HTMX 4 Workflow Engine Integration Specification

## Overview

Upgrade the workflow engine to support HTMX-enhanced partial rendering
with progressive enhancement. Every workflow interaction works as plain
HTML (forms, links, redirects) without JavaScript. HTMX 4 enhances the
experience by intercepting form submissions and swapping content
fragments without full page reloads. The server detects HTMX requests
via the `HX-Request` header and returns fragments (200) instead of
redirects (302).

## Architectural Principles

1. **Progressive enhancement, not dependency.** The plain HTML form
   submission path (POST → 302 redirect → GET → full page) is the
   baseline. HTMX upgrades it. If JS is disabled, broken, or replaced
   by the tenant with React/Alpine/etc., everything still works.

2. **Server framework-agnostic.** The workflow engine checks `HX-Request`
   and responds accordingly. It doesn't know or care what client
   framework is making the request. Tenants can replace HTMX in their
   layout templates via the template editor.

3. **Same template, two modes.** A single template file serves both full
   page (with layout) and fragment (without layout) responses. No
   separate partial templates needed for v1.

4. **URL push on step change only.** When the workflow advances to a new
   step, the browser URL updates via `HX-Push-URL`. Stay actions (same
   step, different view) don't push, keeping history clean.

## Components

### 1. Local Fork of Mojolicious::Plugin::HTMX

**Location:** `lib/Mojolicious/Plugin/HTMX.pm`

Fork the existing CPAN plugin into the project's `lib/` directory.
Update to bundle HTMX 4 and adapt to HTMX 4's API changes:

- Update bundled HTMX JS asset to 4.x
- Update header detection for any HTMX 4 header renames
  (`HX-Request` stays the same, but `HX-Trigger` header format changed)
- Update response helper methods for removed/renamed headers
  (`HX-Trigger-After-Swap` removed, use `HX-Trigger` instead)
- Ensure `app->htmx->asset` serves the HTMX 4 script

The plugin provides:
- `$c->is_htmx_request` -- detect HTMX requests
- `$c->htmx->req->target` -- which element is the swap target
- `$c->htmx->res->push_url($url)` -- update browser URL
- `$c->htmx->res->retarget($selector)` -- override swap target
- `$c->htmx->res->reswap($style)` -- override swap style
- `$c->htmx->res->trigger(@events)` -- fire client events
- `%= app->htmx->asset` -- template helper to load HTMX script

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

### 5. HTMX 4 Attribute Migration

Update existing HTMX attributes in all templates:

| HTMX 1.x/2.x | HTMX 4 | Notes |
|---|---|---|
| `hx-disable` | `hx-ignore` | Skip HTMX processing |
| `hx-disabled-elt` | `hx-disable` | Disable during request |
| `hx-vals` | `hx-vals` | Unchanged |
| `hx-confirm` | `hx-confirm` | Unchanged |
| `hx-swap="outerHTML"` | `hx-swap="outerHTML"` | Unchanged |
| `hx-trigger="load"` | `hx-trigger="load"` | Unchanged |
| `htmx-indicator` CSS | `htmx-indicator` CSS | Unchanged |

Key behavioral change: HTMX 4 swaps ALL HTTP responses by default
including 4xx/5xx. We need to configure per-element or globally:
```javascript
htmx.config.noSwap = [204, 304, '4xx', '5xx'];
```
Or use the new `hx-status` attribute for fine-grained control.

### 6. App Startup Changes

**File:** `lib/Registry.pm`

Register the local HTMX plugin:
```perl
$self->plugin('Mojolicious::Plugin::HTMX');
```

Add global HTMX config via a small inline script in the default layout
or via the plugin's configuration:
```html
<script>
htmx.config.noSwap = ['4xx', '5xx'];
</script>
```

## Error Handling

- **HTMX request with server error:** Return a fragment with the error
  message (not a full error page). HTMX 4 swaps error responses by
  default, so the user sees the error in the content area. With the
  `noSwap` config for 5xx, the content area stays unchanged and the
  error is suppressed (or handled via `htmx:error` event).

- **HTMX request with CSRF failure:** Return 403 with a fragment that
  says "Session expired. Please refresh the page." The noSwap config
  prevents swapping, but we should handle this gracefully.

- **No JS fallback for lazy-loaded sections:** Any `hx-trigger="load"`
  section should have a `<noscript>` fallback or the data should be
  included in the initial server render. For v1, sections that require
  JS to load are acceptable as long as the core workflow functions
  without them.

## Migration Path

### Phase 1: Foundation
1. Fork `Mojolicious::Plugin::HTMX` into `lib/`
2. Update bundled HTMX to version 4
3. Register plugin in `Registry.pm`
4. Update all layout templates to use `%= app->htmx->asset`
5. Remove per-template HTMX CDN script tags
6. Add `noSwap` config for error responses
7. Verify existing HTMX usage still works (subdomain validation,
   admin dashboard lazy loading)

### Phase 2: Workflow Engine
1. Add `is_htmx_request` checks to `process_workflow_run_step`
2. Fragment rendering for step advance, stay, completion, continuation
3. URL push via `htmx->res->push_url` on step changes
4. Add `#workflow-content` swap target to workflow layout
5. Update workflow step templates with `hx-post` + `hx-target`

### Phase 3: Template Migration
1. Update existing HTMX attributes for HTMX 4 compatibility
2. Add `hx-post` progressive enhancement to workflow form templates
3. Ensure all forms have working `method="POST" action="..."` fallbacks
4. Test with JS disabled to verify progressive enhancement

### Phase 4: Admin Dashboard Migration
(Separate spec -- depends on this work being complete)

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

- Local fork of `Mojolicious::Plugin::HTMX` with HTMX 4
- Existing workflow engine with stay semantics
- Existing template infrastructure (DB-first rendering, layouts)

## Notes

- The HTMX script is loaded in layout templates, which are editable
  by tenants via the template editor. A tenant can replace HTMX with
  any client framework. The server-side behavior is unchanged -- it
  checks `HX-Request` and falls back to plain HTML.

- HTMX 4 uses `fetch()` instead of `XMLHttpRequest`. This is
  transparent to the server but may affect client-side error handling
  in custom JavaScript.

- The `innerMorph` swap style in HTMX 4 could be useful for preserving
  form state during re-renders (e.g., keeping cursor position in the
  template editor textarea). This is a future enhancement.
