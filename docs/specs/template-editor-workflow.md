# Template Editor Workflow Specification

## Overview

A workflow for tenant admins to customize their templates through a raw
code editor. Jordan can view all templates in her schema, edit the HTML/EP
content, preview the result, save changes, and revert to the default
version. The template editor is launched from the admin dashboard via
`callcc`, following the same pattern as the tenant-storefront → registration
flow.

## Architectural Context

- **Every user journey is a workflow.** The admin dashboard is a
  single-step listing workflow (like `tenant-storefront`) that `callcc`s
  into admin tool workflows. The template editor is one of those tools.
- **Templates live in the database.** The filesystem is a bootstrap cache.
  Templates are imported into the registry schema at startup, copied to
  tenant schemas during `RegisterTenant`, and served DB-first by the
  Controller render method.
- **Raw editing for v1.** Jordan edits HTML/EP source directly. No-code
  tools will be layered on top later.
- **No restrictions for v1.** All templates in the tenant schema are
  editable. Restrictions can be added later.

## Workflow Definition

```yaml
name: Template Editor
slug: template-editor
description: Admin tool for viewing and customizing tenant templates
first_step: editor
steps:
  - slug: editor
    description: Template list, editor, and preview
    template: template-editor/editor
    class: Registry::DAO::WorkflowSteps::TemplateEditor
```

Single-step workflow using `stay` semantics. The step handles four actions
via POST: `list` (default), `edit`, `preview`, and `save`. The admin stays
on this step throughout the editing session. HTMX handles view transitions.

## Step Class: TemplateEditor

### File

`lib/Registry/DAO/WorkflowSteps/TemplateEditor.pm`

### Process Method

```perl
method process ($db, $form_data, $run = undef) {
    my $action = $form_data->{action} || 'list';

    if ($action eq 'edit') {
        # Load template by ID for editing
        my $template_id = $form_data->{template_id};
        my $template = Registry::DAO::Template->find($db, { id => $template_id });
        return {
            stay => 1,
            template_data => {
                view     => 'edit',
                template => $template,
            },
        };
    }
    elsif ($action eq 'save') {
        # Update template content
        my $template_id = $form_data->{template_id};
        my $content     = $form_data->{content};
        my $template = Registry::DAO::Template->find($db, { id => $template_id });
        $template->update($db, { content => $content });
        return {
            stay => 1,
            template_data => {
                view     => 'edit',
                template => $template,
                saved    => 1,
            },
        };
    }
    elsif ($action eq 'preview') {
        # Return template content for inline preview rendering
        my $template_id = $form_data->{template_id};
        my $content     = $form_data->{content};  # unsaved content from editor
        my $template = Registry::DAO::Template->find($db, { id => $template_id });
        return {
            stay => 1,
            template_data => {
                view            => 'preview',
                template        => $template,
                preview_content => $content,
            },
        };
    }
    elsif ($action eq 'revert') {
        # Replace tenant's template with the registry default
        my $template_id = $form_data->{template_id};
        my $template = Registry::DAO::Template->find($db, { id => $template_id });

        # Load the same-named template from the registry schema
        # (the source this template was originally copied from)
        my $registry_dao = Registry::DAO->new(
            url    => $ENV{DB_URL},
            schema => 'registry',
        );
        my $default = Registry::DAO::Template->find(
            $registry_dao->db,
            { name => $template->name },
        );

        if ($default) {
            $template->update($db, { content => $default->content });
        }

        return {
            stay => 1,
            template_data => {
                view     => 'edit',
                template => $template,
                reverted => 1,
            },
        };
    }
    else {
        # Default: list all templates
        return { stay => 1 };
    }
}
```

### prepare_template_data Method

```perl
method prepare_template_data ($db, $run) {
    $db = $db->db if $db isa Registry::DAO;

    # Load all templates from the tenant's schema
    my @templates = Registry::DAO::Template->find($db, {});

    return {
        view      => 'list',
        templates => \@templates,
        run       => $run,
    };
}
```

## Template: template-editor/editor.html.ep

Single template that renders different views based on the `view` stash
variable. Uses HTMX for smooth transitions.

### List View (default)

Shows a table of all templates with:
- Template name (human-readable, derived from slug)
- Last modified timestamp
- "Edit" button (POSTs `action=edit&template_id=...`)

### Edit View

Shows:
- Template name as heading
- Textarea with current content (monospace font, syntax-highlighting
  optional for v1)
- "Save" button (POSTs `action=save&template_id=...&content=...`)
- "Preview" button (POSTs `action=preview&template_id=...&content=...`)
- "Revert to Default" button (POSTs `action=revert&template_id=...`
  with confirmation dialog)
- "Back to List" button (POSTs `action=list`)
- Success/revert flash messages when applicable

### Preview View

Shows:
- The template rendered with sample data (inline rendering of the
  submitted content)
- "Back to Editor" button
- Note: Preview renders the unsaved content, not the DB content. This
  lets Jordan see changes before committing.

For v1, preview can render the raw EP content in an iframe or a bordered
section. Full sample-data rendering (with mock session/program data) is
a future enhancement.

## Admin Dashboard Integration

The admin dashboard workflow should include a "Template Editor" link that
`callcc`s into the `template-editor` workflow:

```html
<form method="POST"
      action="/<%= $workflow %>/<%= $run->id %>/callcc/template-editor">
    <button type="submit">Template Editor</button>
</form>
```

This follows the same pattern as the storefront's "Register" buttons.

## Routes

No new routes needed. The template editor is a workflow, so it uses the
existing workflow routes:

- `GET /template-editor` → auto-creates run, renders editor step (list view)
- `POST /template-editor/{run_id}/editor` → processes edit/save/preview/revert

The admin dashboard's `callcc` link starts the editor from the dashboard
context.

## Data Model

No schema changes needed. The existing `templates` table has all required
fields:

```sql
templates (
    id uuid PRIMARY KEY,
    name text UNIQUE NOT NULL,
    slug text UNIQUE NOT NULL,
    content text NOT NULL,
    metadata jsonb NULL,
    notes text NULL,
    created_at timestamptz,
    updated_at timestamptz
)
```

The `updated_at` field tracks when Jordan last edited the template.

### Future: Provenance Tracking

When the marketplace launches, templates will need a `source_tenant_id`
or `copied_from_template_id` field to know where to revert to. For v1,
revert always copies from the registry schema.

## Error Handling

- **Template not found**: If `template_id` doesn't match a record, return
  to list view with an error flash.
- **Save failure**: If the DB update fails, return to edit view with the
  unsaved content preserved and an error message.
- **Revert with no default**: If the registry schema doesn't have a
  matching template (custom template created by the tenant), show a
  message: "No default template available for this template."
- **Syntax errors in saved content**: Not validated on save. If Jordan
  saves broken EP syntax, the template will fail to render and the
  filesystem fallback kicks in (since the broken DB template won't render
  successfully). Future: add EP syntax validation before save.

## Security

- **Admin-only access**: The admin dashboard `under` guard requires
  admin/staff role. The template editor, launched via `callcc` from the
  dashboard, inherits this auth check.
- **Schema isolation**: Jordan can only edit templates in her own tenant
  schema. The DAO is scoped to her schema, so `Template->find` only
  returns her templates.
- **No code execution risk**: Templates are EP (Embedded Perl), which
  already runs in the app's Perl process. Jordan can already execute
  arbitrary Perl via EP directives. This is acceptable for admin users.
  Future: sandbox EP execution or switch to a restricted template language
  for non-admin editors.

## Testing Plan

### Perl Controller Tests

**File:** `t/controller/template-editor.t`

1. **List view shows all templates**
   - Import templates into test DB
   - GET `/template-editor` → 200
   - Response contains template names

2. **Edit view loads template content**
   - POST with `action=edit&template_id=...` → stays on step
   - Response contains template content in textarea

3. **Save updates template in DB**
   - POST with `action=save&template_id=...&content=new content`
   - Template record in DB has updated content
   - Response shows success message

4. **Revert restores registry default**
   - Customize a template (save new content)
   - POST with `action=revert&template_id=...`
   - Template content matches registry schema's version

5. **Saved template takes precedence over filesystem**
   - Save a customized template
   - GET a page that uses that template
   - Response contains customized content, not filesystem default

6. **Nonexistent template_id handled gracefully**
   - POST with `action=edit&template_id=bogus-uuid`
   - Returns to list view with error, not 500

### Playwright Browser Tests

**File:** `t/playwright/template-editor.spec.js`

1. **Admin can access template editor**
   - Login as admin
   - Navigate to template editor
   - List of templates visible

2. **Admin can edit and save a template**
   - Click edit on a template
   - Modify content in textarea
   - Click save
   - Success message shown

3. **Saved template renders on public page**
   - Edit the storefront template
   - Add a custom string (e.g., "JORDAN_CUSTOM_MARKER")
   - Navigate to storefront
   - Custom string visible

## Dependencies

- Existing `templates` table and `Registry::DAO::Template` class
- Existing workflow engine with `stay` semantics
- DB-first template rendering in `Registry::Controller::render`
- Admin dashboard workflow for `callcc` launch
- `RegisterTenant` copies templates from registry to tenant schema

## Implementation Order

1. Create `TemplateEditor` step class
2. Create `template-editor.yaml` workflow
3. Create `template-editor/editor.html.ep` template (list/edit/preview)
4. Add `callcc` button to admin dashboard template
5. Add `template-editor` to the `RegisterTenant` workflow copy list
6. Write Perl controller tests
7. Write Playwright browser tests
