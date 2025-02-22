# Template System Architecture

## Overview

The Registry template system is designed to be dynamic and user-modifiable,
with filesystem templates serving only as initial bootstrapping content. This
document explains how templates work, where they're stored, and how to work
with them effectively.

## Core Concepts

### Runtime vs. Bootstrap Templates

- **Runtime Templates**: Stored in the database, these are the actual templates
used by the system. They can be edited through the UI and are tenant-specific.
- **Bootstrap Templates**: Located in `/templates` in the codebase, these
provide initial content and serve as reference implementations. They are only
used to initialize a new system or tenant.

### Template Storage

#### Database Structure
```sql
CREATE TABLE templates (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    name text NOT NULL,
    slug text NOT NULL,
    content text NOT NULL,
    metadata jsonb DEFAULT '{}',
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp NOT NULL DEFAULT current_timestamp,
    UNIQUE(slug)
);
```

The `metadata` field can include:
- Template type (form, email, document, etc.)
- Required permissions
- Associated workflows
- Custom rendering options

### Template Loading Hierarchy

1. **Tenant-Specific Template**: Looked up first in the tenant's schema
2. **Global Template**: Checked in the registry schema if not found in tenant
3. **Filesystem Template**: Used only during initialization

## Working with Templates

### Adding New Templates

1. Create the bootstrap template in `/templates/[workflow-name]/[template-name].html.ep`
2. Add database migration if the template requires specific metadata
3. Add to the workflow definition where needed
4. Test both bootstrapping and runtime modification scenarios

Example template path:
```
/templates/
  ├── location-creation/
  │   ├── index.html.ep
  │   ├── info.html.ep
  │   └── complete.html.ep
  └── event-creation/
      ├── index.html.ep
      └── details.html.ep
```

### Template Structure

Templates use Mojolicious's EP (Embedded Perl) format:

```perl
% layout 'default';  # Optional layout
% title 'Page Title';

<style>
  /* Prefer page-specific styles in <style> blocks */
  .local-class {
    margin: 1rem;
  }
</style>

<div class="content">
  <%= stash('variable') %>
  % for my $item (@$items) {
    <div><%= $item->name %></div>
  % }
</div>
```

### Modifying Templates

Templates can be modified in two ways:

1. **Development/Bootstrap Changes**:
   - Edit files in `/templates/`
   - These changes will only affect new system installations
   - Existing deployments must manually sync changes

2. **Runtime Changes**:
   - Use the template editor in the UI
   - Changes are stored in the database
   - Changes are immediate and tenant-specific

### Template Helpers

Common helpers available in all templates:

```perl
<%= url_for 'route_name' %>          # Generate URLs
<%= param 'field_name' %>            # Access request parameters
<%= stash 'variable_name' %>         # Access template variables
<%= include 'partial' %>             # Include another template
<%= csrf_token %>                    # Generate CSRF token
```

### Best Practices

1. **Style Management**:
   - Use template-specific `<style>` blocks
   - Keep styles close to their usage
   - Avoid inline styles
   - Use semantic class names

2. **Layout and Structure**:
   - Use semantic HTML elements
   - Keep templates focused and single-purpose
   - Break complex templates into partials

3. **Internationalization**:
   - Use string placeholders for text
   - Support RTL languages through CSS
   - Consider cultural differences in layouts

4. **Testing**:
   - Add template tests in `t/templates/`
   - Test with various data scenarios
   - Verify accessibility compliance

### Common Patterns

1. **Form Templates**:
```perl
<form method="POST" action="<%= url_for 'action' %>">
  <%= csrf_field %>
  <div class="form-group">
    <label for="field">Label</label>
    <input type="text" name="field" id="field"
           value="<%= param 'field' %>">
    % if (my $error = validation->error('field')) {
      <span class="error"><%= $error %></span>
    % }
  </div>
</form>
```

2. **List Views**:
```perl
<div class="list">
  % for my $item (@$items) {
    <div class="item">
      <h3><%= $item->title %></h3>
      %= include 'item/details', item => $item
    </div>
  % }
</div>
```

## Runtime Modification

### Template Editor

The system includes a built-in template editor that provides:
- Syntax highlighting
- Live preview
- Version history
- Template variables documentation
- Access control

### Version Control

Template changes are versioned in the database:
- Each edit creates a new version
- Previous versions can be restored
- Changes are tracked with metadata
- Audit log of who made changes

### Template Migration

To propagate template changes across environments:
1. Export templates from source environment
2. Review changes in version control
3. Import to target environment using admin tools
4. Test in staging before production

## Security Considerations

1. **Access Control**:
   - Template editing requires specific permissions
   - Template execution context is controlled
   - Variables are properly escaped

2. **Content Security**:
   - CSP headers are enforced
   - User input is sanitized
   - Template injection is prevented

3. **Audit Trail**:
   - All template modifications are logged
   - Changes can be reverted
   - Author information is preserved

## Troubleshooting

Common issues and solutions:

1. **Template Not Found**:
   - Check template path in workflow
   - Verify tenant permissions
   - Check template exists in database

2. **Rendering Errors**:
   - Validate template syntax
   - Check variable availability
   - Review error logs

3. **Performance Issues**:
   - Monitor template size
   - Check database query count
   - Review template caching

## Future Considerations

Planned improvements to the template system:

1. **Template Marketplace**:
   - Share templates between tenants
   - Template rating system
   - Community contributions

2. **Enhanced Editor**:
   - Component library
   - Visual template builder
   - Automated accessibility checks

3. **Performance Optimizations**:
   - Improved caching
   - Template precompilation
   - Lazy loading of components
