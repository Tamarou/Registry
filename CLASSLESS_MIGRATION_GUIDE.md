# Classless CSS Migration Guide

## Quick Reference: Class to Semantic HTML Mapping

### Layout Components

| Before (With Classes) | After (Classless) |
|--------------------|-----------------|
| `<div class="container">` | `<main>` or `<section>` |
| `<div class="card">` | `<article>` |
| `<div class="card-header">` | `<article><header>` |
| `<div class="card-body">` | `<article><section>` |
| `<div class="card-footer">` | `<article><footer>` |
| `<div class="alert alert-success">` | `<aside role="alert" data-type="success">` |
| `<div class="alert alert-danger">` | `<aside role="alert" data-type="danger">` |

### Typography

| Before (With Classes) | After (Classless) |
|--------------------|-----------------|
| `<span class="text-sm">Small text</span>` | `<small>Small text</small>` |
| `<p class="lead">Lead text</p>` | `<p>Lead text</p>` with CSS `p:first-of-type` |
| `<span class="text-muted">Muted</span>` | `<small>Muted</small>` |
| `<div class="text-center">` | Use semantic structure or minimal class |
| `<strong class="font-bold">` | `<strong>` (styled by default) |

### Forms

| Before (With Classes) | After (Classless) |
|--------------------|-----------------|
| `<div class="form-group">` | `<div>` inside `<form>` |
| `<label class="form-label required">` | `<label required>` |
| `<input class="form-input">` | `<input type="text">` |
| `<select class="form-select">` | `<select>` |
| `<textarea class="form-textarea">` | `<textarea>` |
| `<div class="form-help">Help text</div>` | `<small>Help text</small>` |
| `<div class="form-error">Error</div>` | `<small class="error">Error</small>` |

### Buttons

| Before (With Classes) | After (Classless) |
|--------------------|-----------------|
| `<button class="btn btn-primary">` | `<button>` |
| `<button class="btn btn-secondary">` | `<button data-variant="secondary">` |
| `<button class="btn btn-danger">` | `<button data-variant="danger">` |
| `<button class="btn btn-success">` | `<button data-variant="success">` |
| `<a class="btn btn-primary">` | `<a role="button">` |
| `<button class="btn btn-outline">` | `<button data-variant="outline">` |

## Detailed Migration Examples

### Example 1: Simple Card Component

**Before:**
```html
<div class="card">
  <div class="card-header">
    <h3 class="card-title">Program Details</h3>
  </div>
  <div class="card-body">
    <p class="text-sm text-muted">Information about the program.</p>
  </div>
  <div class="card-footer">
    <button class="btn btn-primary">Enroll Now</button>
  </div>
</div>
```

**After:**
```html
<article>
  <header>
    <h3>Program Details</h3>
  </header>
  <section>
    <p><small>Information about the program.</small></p>
  </section>
  <footer>
    <button>Enroll Now</button>
  </footer>
</article>
```

### Example 2: Form Section

**Before:**
```html
<form class="profile-form">
  <div class="form-section">
    <h3 class="section-title">Organization Information</h3>

    <div class="form-group">
      <label for="name" class="form-label required">Organization Name</label>
      <input type="text" class="form-input" id="name" name="name" required>
      <div class="form-help">This will be displayed to families</div>
    </div>

    <div class="form-group">
      <label for="type" class="form-label">Organization Type</label>
      <select class="form-select" id="type" name="type">
        <option>School</option>
        <option>Community Center</option>
      </select>
    </div>
  </div>

  <div class="form-actions">
    <button type="submit" class="btn btn-primary btn-lg">
      Continue →
    </button>
  </div>
</form>
```

**After:**
```html
<form>
  <fieldset>
    <legend>Organization Information</legend>

    <div>
      <label for="name" required>Organization Name</label>
      <input type="text" id="name" name="name" required>
      <small>This will be displayed to families</small>
    </div>

    <div>
      <label for="type">Organization Type</label>
      <select id="type" name="type">
        <option>School</option>
        <option>Community Center</option>
      </select>
    </div>
  </fieldset>

  <div>
    <button type="submit">
      Continue →
    </button>
  </div>
</form>
```

### Example 3: Dashboard Stats

**Before:**
```html
<div class="stats-grid">
  <div class="stat-card">
    <div class="stat-content">
      <div class="stat-icon blue">
        <svg>...</svg>
      </div>
      <div class="stat-details">
        <h3 class="text-sm font-medium text-gray-700">Active Enrollments</h3>
        <p class="stat-value text-2xl font-semibold">247</p>
      </div>
    </div>
  </div>
</div>
```

**After:**
```html
<section>
  <dl>
    <dt>Active Enrollments</dt>
    <dd>247</dd>

    <dt>Active Programs</dt>
    <dd>12</dd>
  </dl>
</section>
```

### Example 4: Alert Messages

**Before:**
```html
<div class="alert alert-success">
  <strong>Success!</strong> Your profile has been updated.
</div>

<div class="alert alert-danger">
  <strong>Error:</strong> Please fix the validation errors below.
</div>
```

**After:**
```html
<aside role="alert" data-type="success">
  <strong>Success!</strong> Your profile has been updated.
</aside>

<aside role="alert" data-type="danger">
  <strong>Error:</strong> Please fix the validation errors below.
</aside>
```

### Example 5: Navigation

**Before:**
```html
<nav class="navbar">
  <ul class="nav-list flex items-center gap-4">
    <li class="nav-item">
      <a href="/" class="nav-link active">Dashboard</a>
    </li>
    <li class="nav-item">
      <a href="/programs" class="nav-link">Programs</a>
    </li>
  </ul>
</nav>
```

**After:**
```html
<nav>
  <ul>
    <li><a href="/" aria-current="page">Dashboard</a></li>
    <li><a href="/programs">Programs</a></li>
  </ul>
</nav>
```

## Classes That Must Be Retained

### JavaScript Hooks
These classes are used by JavaScript and must be preserved:

```html
<!-- HTMX -->
<div class="htmx-indicator">Loading...</div>

<!-- Visibility Toggle -->
<div class="hidden" id="dropdown-menu">...</div>

<!-- Error States -->
<input type="text" class="error">

<!-- Loading States -->
<div class="loading">
  <span class="spinner"></span>
</div>
```

### Special Components
Some components require minimal classes:

```html
<!-- Hero section needs gradient background -->
<section class="hero">
  <h1>Welcome</h1>
</section>

<!-- Modal needs positioning -->
<div class="modal-overlay">
  <div class="modal-content">
    ...
  </div>
</div>
```

## Template Conversion Script

Here's a basic sed script to automate common conversions:

```bash
#!/bin/bash
# convert-to-classless.sh

# Backup original file
cp "$1" "$1.bak"

# Replace common patterns
sed -i '
  # Cards
  s/<div class="card">/<article>/g
  s/<\/div><!-- end card -->/<\/article>/g
  s/<div class="card-header">/<header>/g
  s/<div class="card-body">/<section>/g
  s/<div class="card-footer">/<footer>/g

  # Forms
  s/<div class="form-group">/<div>/g
  s/class="form-label required"/required/g
  s/class="form-label"//g
  s/class="form-input"//g
  s/class="form-select"//g
  s/class="form-textarea"//g
  s/<div class="form-help">/<small>/g
  s/<\/div><!-- end form-help -->/<\/small>/g

  # Buttons
  s/class="btn btn-primary"//g
  s/class="btn btn-secondary"/data-variant="secondary"/g
  s/class="btn btn-danger"/data-variant="danger"/g
  s/class="btn btn-success"/data-variant="success"/g

  # Typography
  s/<span class="text-sm">/<small>/g
  s/<\/span><!-- end text-sm -->/<\/small>/g
  s/<span class="text-muted">/<small>/g
  s/<\/span><!-- end text-muted -->/<\/small>/g

  # Alerts
  s/<div class="alert alert-success">/<aside role="alert" data-type="success">/g
  s/<div class="alert alert-danger">/<aside role="alert" data-type="danger">/g
  s/<div class="alert alert-warning">/<aside role="alert" data-type="warning">/g
  s/<div class="alert alert-info">/<aside role="alert" data-type="info">/g
' "$1"
```

## Testing Checklist

After migrating a template, verify:

- [ ] Visual appearance matches original
- [ ] Forms submit correctly
- [ ] HTMX interactions work
- [ ] Buttons have correct styling
- [ ] Error states display properly
- [ ] Loading indicators appear
- [ ] JavaScript functionality preserved
- [ ] Mobile responsiveness maintained
- [ ] Accessibility improved (test with screen reader)

## Gradual Migration Strategy

1. **Phase 1**: Add classless.css alongside existing CSS
2. **Phase 2**: Migrate one workflow at a time
3. **Phase 3**: Update shared components
4. **Phase 4**: Remove unused classes from registry.css
5. **Phase 5**: Merge remaining styles into classless.css

## Benefits After Migration

- **HTML Size**: ~30% reduction in template size
- **CSS Size**: ~60% reduction in CSS file size
- **Developer Experience**: Write semantic HTML naturally
- **Maintenance**: Easier to update styles globally
- **Accessibility**: Better screen reader support by default