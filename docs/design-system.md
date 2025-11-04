# Registry Design System Specification

## 1. Color Palette

### CSS Custom Properties

```css
:root {
    /* Light Theme Colors */
    --bg-primary: #f0e6ff;        /* Primary background - Light purple */
    --bg-secondary: #fff5f5;      /* Secondary background - Light pink */
    --text-primary: #2a1b3d;      /* Primary text - Dark purple */
    --text-secondary: #44306e;    /* Secondary text - Medium purple */
    --accent-pink: #ff00ff;       /* Accent - Magenta */
    --accent-cyan: #00ffff;       /* Accent - Cyan */
    --accent-purple: #9d4edd;     /* Accent - Purple */
    --accent-blue: #7209b7;       /* Accent - Deep purple */

    /* Gradients */
    --gradient-1: linear-gradient(135deg, #667eea 0%, #ff00ff 50%, #00ffff 100%);
    --gradient-2: linear-gradient(45deg, #f093fb 0%, #f5576c 100%);

    /* Glassmorphism & Effects */
    --card-bg: rgba(255, 255, 255, 0.85);
    --glow-color: rgba(255, 0, 255, 0.3);
    --grid-color: rgba(157, 78, 221, 0.1);
}

[data-theme="dark"] {
    /* Dark Theme Colors */
    --bg-primary: #0a0014;        /* Primary background - Deep purple-black */
    --bg-secondary: #1a0829;      /* Secondary background - Purple-black */
    --text-primary: #ffffff;      /* Primary text - White */
    --text-secondary: #e0b3ff;    /* Secondary text - Light purple */
    --accent-pink: #ff00ff;       /* Accent - Magenta (unchanged) */
    --accent-cyan: #00ffff;       /* Accent - Cyan (unchanged) */
    --accent-purple: #c77dff;     /* Accent - Light purple */
    --accent-blue: #9d4edd;       /* Accent - Medium purple */

    /* Gradients (same for both themes) */
    --gradient-1: linear-gradient(135deg, #667eea 0%, #ff00ff 50%, #00ffff 100%);
    --gradient-2: linear-gradient(45deg, #f093fb 0%, #f5576c 100%);

    /* Glassmorphism & Effects */
    --card-bg: rgba(26, 8, 41, 0.85);
    --glow-color: rgba(255, 0, 255, 0.5);
    --grid-color: rgba(157, 78, 221, 0.2);
}
```

## 2. Typography System

### Font Families
```css
/* Primary Font Stack */
font-family: 'Segoe UI', system-ui, -apple-system, sans-serif;

/* Monospace Font (for branding/technical elements) */
font-family: 'Courier New', monospace;
```

### Font Sizes (Responsive)
```css
/* Hero Title */
font-size: clamp(2.5rem, 8vw, 5rem);

/* Section Titles */
font-size: 3rem;  /* Desktop */
font-size: 2rem;  /* Mobile (@media max-width: 768px) */

/* Subsection Titles */
font-size: 2.5rem;

/* Hero Subtitle */
font-size: 1.5rem;  /* Desktop */
font-size: 1.2rem;  /* Mobile */

/* Logo */
font-size: 1.8rem;

/* Feature Titles */
font-size: 1.5rem;

/* Button Text */
font-size: 1.2rem;  /* Large CTA */
font-size: 1rem;    /* Standard buttons */

/* Body Text */
font-size: 1rem;
line-height: 1.6;
```

### Text Styles
```css
/* Logo Style */
.logo-text {
    font-weight: bold;
    letter-spacing: 3px;
    text-transform: uppercase;
}

/* CTA Button Text */
.button-text-primary {
    font-weight: bold;
    text-transform: uppercase;
    letter-spacing: 2px;
}

/* Standard Button Text */
.button-text-secondary {
    font-weight: bold;
}
```

## 3. Component Patterns

### 3.1 Buttons

#### Primary CTA Button
```css
.cta-button {
    background: var(--gradient-1);
    color: white;
    border: none;
    padding: 1.2rem 3rem;
    font-size: 1.2rem;
    border-radius: 50px;
    cursor: pointer;
    font-weight: bold;
    text-transform: uppercase;
    letter-spacing: 2px;
    transition: all 0.3s ease;
    box-shadow: 0 10px 30px rgba(255, 0, 255, 0.3);
}

.cta-button:hover {
    transform: translateY(-3px);
    box-shadow: 0 15px 40px rgba(255, 0, 255, 0.5);
}
```

#### Secondary Submit Button
```css
.submit-button {
    background: var(--gradient-2);
    color: white;
    border: none;
    padding: 1rem 2rem;
    border-radius: 50px;
    font-size: 1rem;
    font-weight: bold;
    cursor: pointer;
    transition: all 0.3s ease;
}

.submit-button:hover {
    transform: scale(1.05);
    box-shadow: 0 10px 30px rgba(245, 87, 108, 0.5);
}
```

#### Icon Button (Theme Toggle)
```css
.icon-button {
    background: transparent;
    border: 2px solid var(--accent-purple);
    color: var(--accent-purple);
    padding: 0.5rem;
    border-radius: 50%;
    cursor: pointer;
    font-size: 1.2rem;
    transition: all 0.3s ease;
}

.icon-button:hover {
    background: var(--accent-purple);
    color: white;
    box-shadow: 0 0 20px var(--accent-purple);
}
```

### 3.2 Cards

#### Feature Card
```css
.feature-card {
    background: var(--card-bg);
    padding: 2rem;
    border-radius: 20px;
    border: 2px solid var(--glow-color);
    backdrop-filter: blur(10px);
    transition: all 0.3s ease;
}

.feature-card:hover {
    transform: translateY(-10px);
    box-shadow: 0 20px 40px var(--glow-color);
    border-color: var(--accent-cyan);
}
```

### 3.3 Forms

#### Input Field
```css
.form-input {
    padding: 1rem 1.5rem;
    border: 2px solid var(--accent-purple);
    background: var(--card-bg);
    color: var(--text-primary);
    border-radius: 50px;
    font-size: 1rem;
    transition: all 0.3s ease;
}

.form-input:focus {
    outline: none;
    border-color: var(--accent-cyan);
    box-shadow: 0 0 20px var(--accent-cyan);
}
```

### 3.4 Navigation

#### Fixed Navigation Bar
```css
.navbar {
    position: fixed;
    top: 0;
    width: 100%;
    padding: 1.5rem 2rem;
    background: var(--card-bg);
    backdrop-filter: blur(10px);
    z-index: 100;
    display: flex;
    justify-content: space-between;
    align-items: center;
    border-bottom: 2px solid var(--glow-color);
}
```

### 3.5 Text Effects

#### Gradient Text
```css
.gradient-text {
    background: var(--gradient-1);
    -webkit-background-clip: text;
    background-clip: text;
    -webkit-text-fill-color: transparent;
}

.gradient-text-alt {
    background: var(--gradient-2);
    -webkit-background-clip: text;
    background-clip: text;
    -webkit-text-fill-color: transparent;
}
```

## 4. Layout System

### 4.1 Spacing Scale
```css
/* Padding/Margin Scale */
--space-xs: 0.5rem;
--space-sm: 1rem;
--space-md: 1.5rem;
--space-lg: 2rem;
--space-xl: 3rem;
--space-2xl: 4rem;
```

### 4.2 Container Widths
```css
.container {
    max-width: 1200px;
    margin: 0 auto;
    padding: 0 2rem;
}

.container-narrow {
    max-width: 600px;
}

.container-form {
    max-width: 500px;
}
```

### 4.3 Grid System
```css
.grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
    gap: 2rem;
}
```

### 4.4 Responsive Breakpoints
```css
/* Mobile */
@media (max-width: 768px) {
    /* Adjustments for mobile */
}

/* Tablet */
@media (min-width: 769px) and (max-width: 1024px) {
    /* Tablet-specific styles */
}

/* Desktop */
@media (min-width: 1025px) {
    /* Desktop-specific styles */
}
```

## 5. Animation & Effects

### 5.1 Keyframe Animations

#### Glow Pulse
```css
@keyframes glow-pulse {
    0%, 100% { filter: drop-shadow(0 0 20px var(--glow-color)); }
    50% { filter: drop-shadow(0 0 40px var(--glow-color)); }
}
```

#### Grid Movement
```css
@keyframes grid-move {
    0% { transform: translate(0, 0); }
    100% { transform: translate(50px, 50px); }
}
```

#### Float Animation
```css
@keyframes float-1 {
    0%, 100% { transform: translate(0, 0) rotate(0deg); }
    50% { transform: translate(100px, -50px) rotate(180deg); }
}

@keyframes float-2 {
    0%, 100% { transform: translate(0, 0) rotate(0deg); }
    50% { transform: translate(-80px, 30px) rotate(-180deg); }
}
```

### 5.2 Transitions
```css
/* Standard transition */
transition: all 0.3s ease;

/* Theme transition */
transition: background 0.3s ease, color 0.3s ease;
```

### 5.3 Hover Effects
```css
/* Lift effect */
.hover-lift:hover {
    transform: translateY(-10px);
}

/* Scale effect */
.hover-scale:hover {
    transform: scale(1.05);
}

/* Glow effect */
.hover-glow:hover {
    box-shadow: 0 20px 40px var(--glow-color);
}
```

## 6. Background Effects

### 6.1 Grid Background
```css
.grid-background {
    position: fixed;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    background-image:
        linear-gradient(var(--grid-color) 1px, transparent 1px),
        linear-gradient(90deg, var(--grid-color) 1px, transparent 1px);
    background-size: 50px 50px;
    z-index: -2;
    animation: grid-move 20s linear infinite;
}
```

### 6.2 Floating Shapes
```css
.floating-shape {
    position: absolute;
    opacity: 0.3;
}

.shape-blob {
    background: var(--gradient-1);
    border-radius: 30% 70% 70% 30% / 30% 30% 70% 70%;
}

.shape-triangle {
    background: var(--gradient-2);
    clip-path: polygon(50% 0%, 0% 100%, 100% 100%);
}
```

## 7. Glassmorphism Effects

### Glass Card
```css
.glass-card {
    background: var(--card-bg);
    backdrop-filter: blur(10px);
    border: 2px solid var(--glow-color);
    border-radius: 20px;
}
```

## 8. Usage Guidelines

### Component Hierarchy
1. **Primary Actions**: Use `cta-button` with `--gradient-1`
2. **Secondary Actions**: Use `submit-button` with `--gradient-2`
3. **Tertiary Actions**: Use transparent buttons with borders

### Color Application
- **Backgrounds**: Use `--bg-primary` for main sections, `--bg-secondary` for alternating sections
- **Text**: Use `--text-primary` for headers, `--text-secondary` for body text
- **Accents**: Use sparingly for interactive elements and highlights

### Accessibility Considerations
1. **Color Contrast**: Ensure minimum WCAG AA compliance (4.5:1 for normal text, 3:1 for large text)
2. **Focus States**: All interactive elements must have visible focus indicators
3. **Keyboard Navigation**: All interactive elements must be keyboard accessible
4. **Screen Readers**: Use semantic HTML and ARIA labels where necessary

### Responsive Design Patterns
1. **Mobile-First**: Start with mobile layout and enhance for larger screens
2. **Fluid Typography**: Use `clamp()` for responsive font sizes
3. **Flexible Grids**: Use `auto-fit` and `minmax()` for responsive grids
4. **Touch Targets**: Minimum 44x44px for mobile touch targets

## 9. Implementation Examples

### Basic Page Template
```html
<body data-theme="light">
    <!-- Background Effects -->
    <div class="grid-background"></div>
    <div class="floating-shapes">
        <div class="shape shape-blob"></div>
        <div class="shape shape-triangle"></div>
    </div>

    <!-- Navigation -->
    <nav class="navbar">
        <div class="logo gradient-text">Registry</div>
        <div class="nav-buttons">
            <!-- Navigation items -->
        </div>
    </nav>

    <!-- Main Content -->
    <main>
        <section class="hero">
            <h1 class="gradient-text">Title</h1>
            <p class="hero-subtitle">Subtitle</p>
            <button class="cta-button">Action</button>
        </section>

        <section class="features">
            <div class="container">
                <div class="grid">
                    <div class="feature-card">
                        <!-- Card content -->
                    </div>
                </div>
            </div>
        </section>
    </main>

    <!-- Footer -->
    <footer>
        <!-- Footer content -->
    </footer>
</body>
```

### Theme Toggle Implementation
```javascript
function toggleTheme() {
    const body = document.body;
    const currentTheme = body.getAttribute('data-theme');
    const newTheme = currentTheme === 'light' ? 'dark' : 'light';

    body.setAttribute('data-theme', newTheme);
    localStorage.setItem('theme', newTheme);
}

// Load saved theme on page load
window.addEventListener('load', () => {
    const savedTheme = localStorage.getItem('theme') || 'light';
    document.body.setAttribute('data-theme', savedTheme);
});
```

## 10. Design Tokens Summary

### Border Radius
- **Buttons**: 50px (pill shape)
- **Cards**: 20px
- **Icons**: 50% (circular)

### Shadows
- **Default**: `0 10px 30px rgba(255, 0, 255, 0.3)`
- **Hover**: `0 15px 40px rgba(255, 0, 255, 0.5)`
- **Glow**: `0 0 20px var(--accent-color)`

### Blur Effects
- **Backdrop**: `blur(10px)`

### Opacity
- **Background Shapes**: 0.3
- **Glass Cards**: 0.85

## 11. CSS File Structure & Organization

The Registry design system is organized across four main CSS files:

### File Import Order
```html
<!-- In templates: Import in this specific order -->
<link rel="stylesheet" href="/css/design-system.css">
<link rel="stylesheet" href="/css/components.css">
<link rel="stylesheet" href="/css/structure.css">
<link rel="stylesheet" href="/css/style.css"> <!-- Optional: Legacy support -->
```

### File Responsibilities

#### `/public/css/design-system.css`
- Core design tokens and CSS custom properties
- Theme definitions (light/dark)
- Keyframe animations
- Background effects
- Base body/html styles

#### `/public/css/components.css`
- Reusable component styles (navigation, buttons, cards, forms)
- Hero sections
- Landing page components
- Feature cards
- Navigation patterns

#### `/public/css/structure.css`
- Extended design tokens (typography, spacing, shadows)
- Semantic HTML element styling
- Base element reset/normalization
- Semantic color palette

#### `/public/css/style.css`
- Utility classes (display, flex, grid, text, spacing)
- Page-specific styles
- Legacy button classes (backward compatibility)
- Container system

## 12. Extended Design Tokens

### Semantic Color Palette
```css
:root {
    --color-primary: #BF349A;    /* Magenta for primary actions */
    --color-secondary: #2ABFBF;  /* Cyan for secondary actions */
    --color-success: #29A6A6;    /* Teal */
    --color-warning: #BF349A;    /* Magenta */
    --color-danger: #8C2771;     /* Deep purple */
    --color-info: #2ABFBF;       /* Cyan */
}
```

### Complete Spacing Scale
```css
:root {
    --space-0: 0;
    --space-1: 0.25rem;   /* 4px */
    --space-2: 0.5rem;    /* 8px */
    --space-3: 0.75rem;   /* 12px */
    --space-4: 1rem;      /* 16px */
    --space-5: 1.25rem;   /* 20px */
    --space-6: 1.5rem;    /* 24px */
    --space-7: 1.75rem;   /* 28px */
    --space-8: 2rem;      /* 32px */
    --space-10: 2.5rem;   /* 40px */
    --space-12: 3rem;     /* 48px */
    --space-16: 4rem;     /* 64px */
    --space-20: 5rem;     /* 80px */
    --space-24: 6rem;     /* 96px */
}
```

### Complete Typography Scale
```css
:root {
    /* Font Sizes */
    --font-size-xs: 0.75rem;    /* 12px */
    --font-size-sm: 0.875rem;   /* 14px */
    --font-size-base: 1rem;     /* 16px */
    --font-size-lg: 1.125rem;   /* 18px */
    --font-size-xl: 1.25rem;    /* 20px */
    --font-size-2xl: 1.5rem;    /* 24px */
    --font-size-3xl: 1.875rem;  /* 30px */
    --font-size-4xl: 2.25rem;   /* 36px */
    --font-size-5xl: 3rem;      /* 48px */

    /* Font Weights */
    --font-weight-normal: 400;
    --font-weight-medium: 500;
    --font-weight-semibold: 600;
    --font-weight-bold: 700;

    /* Line Heights */
    --line-height-tight: 1.25;
    --line-height-normal: 1.5;
    --line-height-relaxed: 1.75;
}
```

### Shadow System
```css
:root {
    --shadow-sm: 0 1px 2px 0 rgb(0 0 0 / 0.05);
    --shadow-base: 0 1px 3px 0 rgb(0 0 0 / 0.1), 0 1px 2px -1px rgb(0 0 0 / 0.1);
    --shadow-md: 0 4px 6px -1px rgb(0 0 0 / 0.1), 0 2px 4px -2px rgb(0 0 0 / 0.1);
    --shadow-lg: 0 10px 15px -3px rgb(0 0 0 / 0.1), 0 4px 6px -4px rgb(0 0 0 / 0.1);
    --shadow-xl: 0 20px 25px -5px rgb(0 0 0 / 0.1), 0 8px 10px -6px rgb(0 0 0 / 0.1);
}
```

### Border Radius Scale
```css
:root {
    --radius-none: 0;
    --radius-sm: 0.125rem;   /* 2px */
    --radius-base: 0.25rem;  /* 4px */
    --radius-md: 0.375rem;   /* 6px */
    --radius-lg: 0.5rem;     /* 8px */
    --radius-xl: 0.75rem;    /* 12px */
    --radius-2xl: 1rem;      /* 16px */
    --radius-full: 9999px;
}
```

### Transition Speeds
```css
:root {
    --transition-fast: 150ms ease-in-out;
    --transition-base: 250ms ease-in-out;
    --transition-slow: 350ms ease-in-out;
}
```

## 13. Workflow-Specific Components

### Workflow Layout
```css
body[data-layout="workflow"] {
    /* Workflow-specific styling */
    background: var(--bg-primary);
}

/* Background grid effect for workflows */
body[data-layout="workflow"]::before {
    content: '';
    position: fixed;
    top: -50px;
    left: -50px;
    width: calc(100% + 50px);
    height: calc(100% + 50px);
    background-image:
        linear-gradient(var(--grid-color) 1px, transparent 1px),
        linear-gradient(90deg, var(--grid-color) 1px, transparent 1px);
    background-size: 50px 50px;
    z-index: -2;
    animation: grid-move 20s linear infinite;
}

/* Floating shape for workflows */
body[data-layout="workflow"]::after {
    content: '';
    position: fixed;
    width: 300px;
    height: 300px;
    background: var(--gradient-1);
    border-radius: 30% 70% 70% 30% / 30% 30% 70% 70%;
    animation: float-subtle 25s infinite ease-in-out;
    opacity: 0.15;
    z-index: -1;
}
```

### Workflow Components
```css
/* Workflow Header */
header[data-component="workflow-header"] {
    text-align: center;
    margin-bottom: 2rem;
    padding: 2rem;
    background: var(--card-bg);
    backdrop-filter: blur(10px);
    border-radius: 20px;
}

/* Workflow Content Section */
section[data-component="workflow-content"] {
    background: var(--card-bg);
    backdrop-filter: blur(10px);
    border-radius: 20px;
    border: 2px solid var(--glow-color);
    padding: 2rem;
    margin-bottom: 2rem;
}

/* Workflow Navigation Footer */
footer[data-component="workflow-navigation"] {
    display: flex;
    justify-content: space-between;
    gap: 1rem;
    padding: 1.5rem;
    background: var(--card-bg);
    backdrop-filter: blur(10px);
    border-radius: 20px;
}

/* Workflow container */
div[data-component="workflow-container"] {
    max-width: 800px;
    margin: 0 auto;
    padding: 2rem;
}
```

### Workflow Form Elements
```css
/* Inputs within workflow content */
section[data-component="workflow-content"] input[type="text"],
section[data-component="workflow-content"] input[type="email"],
section[data-component="workflow-content"] input[type="tel"],
section[data-component="workflow-content"] input[type="date"] {
    width: 100%;
    padding: 1rem 1.5rem;
    border: 2px solid var(--accent-purple);
    background: var(--card-bg);
    color: var(--text-primary);
    border-radius: 50px;
    font-size: 1rem;
    transition: all 0.3s ease;
}

section[data-component="workflow-content"] textarea {
    border-radius: 1rem; /* Less rounded than text inputs */
}

section[data-component="workflow-content"] select {
    border-radius: 50px;
    padding-right: 2.5rem; /* Space for dropdown arrow */
}
```

## 14. HTMX Integration Patterns

### Loading States
```css
/* Disable interaction during HTMX requests */
.htmx-request section[data-component="workflow-content"] {
    opacity: 0.6;
    pointer-events: none;
}

/* Show loading indicators during requests */
.htmx-indicator {
    display: none;
}
.htmx-request .htmx-indicator {
    display: flex;
    justify-content: center;
    align-items: center;
}

/* Spinner animation for loading */
.spinner {
    border: 3px solid var(--glow-color);
    border-top-color: var(--accent-purple);
    border-radius: 50%;
    width: 40px;
    height: 40px;
    animation: spin 1s linear infinite;
}

@keyframes spin {
    0% { transform: rotate(0deg); }
    100% { transform: rotate(360deg); }
}
```

### Swap Transitions
```css
/* Smooth transitions for HTMX content swaps */
.htmx-swapping {
    opacity: 0;
    transition: opacity var(--transition-base);
}

.htmx-settling {
    opacity: 1;
    transition: opacity var(--transition-base);
}
```

## 15. Utility Classes

### Display Utilities
```css
.d-none { display: none; }
.d-block { display: block; }
.d-inline { display: inline; }
.d-inline-block { display: inline-block; }
.d-flex { display: flex; }
.d-inline-flex { display: inline-flex; }
.d-grid { display: grid; }
```

### Flexbox Utilities
```css
/* Flex Direction */
.flex-row { flex-direction: row; }
.flex-column { flex-direction: column; }
.flex-wrap { flex-wrap: wrap; }
.flex-nowrap { flex-wrap: nowrap; }

/* Justify Content */
.justify-start { justify-content: flex-start; }
.justify-center { justify-content: center; }
.justify-end { justify-content: flex-end; }
.justify-between { justify-content: space-between; }
.justify-around { justify-content: space-around; }
.justify-evenly { justify-content: space-evenly; }

/* Align Items */
.items-start { align-items: flex-start; }
.items-center { align-items: center; }
.items-end { align-items: flex-end; }
.items-baseline { align-items: baseline; }
.items-stretch { align-items: stretch; }
```

### Spacing Utilities
```css
/* Padding */
.p-0 { padding: var(--space-0); }
.p-1 { padding: var(--space-1); }
.p-2 { padding: var(--space-2); }
.p-4 { padding: var(--space-4); }
.p-6 { padding: var(--space-6); }
.p-8 { padding: var(--space-8); }

/* Margin */
.m-0 { margin: var(--space-0); }
.m-2 { margin: var(--space-2); }
.m-4 { margin: var(--space-4); }
.m-6 { margin: var(--space-6); }
.m-8 { margin: var(--space-8); }

/* Directional margin/padding available: .mt-*, .mb-*, .ml-*, .mr-* */
```

### Text Utilities
```css
/* Text Color */
.text-primary { color: var(--text-primary); }
.text-secondary { color: var(--text-secondary); }
.text-success { color: var(--color-success); }
.text-danger { color: var(--color-danger); }
.text-warning { color: var(--color-warning); }
.text-info { color: var(--color-info); }
.text-muted { color: var(--text-secondary); opacity: 0.7; }

/* Font Weight */
.font-normal { font-weight: var(--font-weight-normal); }
.font-medium { font-weight: var(--font-weight-medium); }
.font-semibold { font-weight: var(--font-weight-semibold); }
.font-bold { font-weight: var(--font-weight-bold); }
```

### Accessibility Utilities
```css
/* Screen reader only */
.sr-only {
    position: absolute;
    width: 1px;
    height: 1px;
    padding: 0;
    margin: -1px;
    overflow: hidden;
    clip: rect(0, 0, 0, 0);
    white-space: nowrap;
    border: 0;
}
```

## 16. Web Components

The Registry system includes custom web components built with Web Components API.

### Workflow Progress Component

Custom element: `<workflow-progress>`

#### Attributes
```html
<workflow-progress
    data-current-step="2"
    data-total-steps="5"
    data-step-names='["Info", "Payment", "Review", "Submit", "Complete"]'
    data-step-urls='["/step1", "/step2", "/step3", "/step4", "/step5"]'
    data-completed-steps='["1"]'>
</workflow-progress>
```

#### Features
- Shadow DOM encapsulation for style isolation
- Breadcrumb-style progress indicator
- Interactive navigation (click to visit completed steps)
- Keyboard accessible (Enter/Space for navigation)
- HTMX integration for seamless page navigation
- Responsive: hides step names on mobile devices
- Visual states: completed (✓), current (highlighted), upcoming

#### Internal Styling
```css
/* Defined within Shadow DOM */
.progress-step {
    display: flex;
    align-items: center;
    gap: 0.5rem;
}

.step-indicator.completed {
    background: linear-gradient(135deg, #29A6A6, #2ABFBF);
}

.step-indicator.current {
    background: linear-gradient(135deg, #667eea, #9d4edd);
    animation: pulse-glow 2s ease-in-out infinite;
}

@keyframes pulse-glow {
    0%, 100% {
        box-shadow: 0 5px 15px rgba(157, 78, 221, 0.4);
    }
    50% {
        box-shadow: 0 5px 20px rgba(157, 78, 221, 0.6);
    }
}
```

#### Usage Example
```html
<!-- In workflow templates -->
<workflow-progress
    data-current-step="<%= $current_step %>"
    data-total-steps="<%= $total_steps %>"
    data-step-names='<%= $step_names_json %>'
    data-step-urls='<%= $step_urls_json %>'
    data-completed-steps='<%= $completed_steps_json %>'>
</workflow-progress>
```

### Form Builder Component

Custom element: `<form-builder>`

#### Features
- Dynamic form generation from JSON Schema
- Automatic validation
- Support for multiple field types
- Error messaging
- HTMX-compatible form submission

#### Field Types Supported
- `text`, `email`, `tel`, `url`
- `textarea`
- `select` (with options)
- `radio`, `checkbox`
- `date`, `time`, `datetime-local`
- `number`, `range`

#### Usage Example
```html
<form-builder
    data-schema='<%= $form_schema_json %>'
    data-action="/api/submit"
    data-method="POST">
</form-builder>
```

## 17. Data Attribute Conventions

### Layout Control
```html
<!-- Activates workflow-specific styling -->
<body data-layout="workflow">

<!-- Controls color theme -->
<body data-theme="dark">  <!-- or "light" -->

<!-- Landing page theme override -->
<body data-landing-theme="dark">
```

### Component Identification
```html
<!-- Workflow components -->
<header data-component="workflow-header">
<section data-component="workflow-content">
<footer data-component="workflow-navigation">
<div data-component="workflow-container">

<!-- Progress tracking -->
<div data-component="workflow-progress">
```

### Button Variants
```html
<!-- Using data attributes for button styling -->
<button data-variant="primary">Primary Action</button>
<button data-variant="secondary">Secondary Action</button>
<button data-variant="success">Success</button>
<button data-variant="danger">Delete</button>
<button data-variant="outline">Outline</button>

<!-- Button sizes -->
<button data-size="sm">Small</button>
<button data-size="lg">Large</button>
<button data-size="xl">Extra Large</button>
```

## 18. Integration with Registry Application

### Current Implementation Status
The design system is **fully integrated** into Registry's Mojolicious templates:

- ✅ CSS files organized in `/public/css/`
- ✅ Base layouts include design system (`templates/layouts/`)
- ✅ Component classes applied throughout templates
- ✅ HTMX compatibility maintained
- ✅ Theme toggle implemented with system preference detection
- ✅ Web components deployed
- ✅ Responsive design patterns in use

### Template Integration Examples

#### Layout Integration
```perl
# In templates/layouts/workflow.html.ep
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title><%= title %></title>

    <!-- Design system CSS -->
    <link rel="stylesheet" href="/css/design-system.css">
    <link rel="stylesheet" href="/css/components.css">
    <link rel="stylesheet" href="/css/structure.css">

    <!-- HTMX -->
    <script src="https://unpkg.com/htmx.org@1.9.10"></script>

    <!-- Web Components -->
    <script src="/js/components/workflow-progress.js"></script>
</head>
<body data-layout="workflow" data-theme="light">
    <%= content %>

    <!-- Theme toggle script -->
    <script>
        // Theme detection and toggle implementation
    </script>
</body>
</html>
```

#### Workflow Template Example
```perl
# In templates/workflow/registration_step.html.ep
<div data-component="workflow-container">
    <header data-component="workflow-header">
        <h1 class="gradient-text"><%= $step_title %></h1>
        <p><%= $step_description %></p>
    </header>

    <workflow-progress
        data-current-step="<%= $current_step %>"
        data-total-steps="<%= $total_steps %>"
        data-step-names='<%= $step_names_json %>'
        data-step-urls='<%= $step_urls_json %>'
        data-completed-steps='<%= $completed_steps_json %>'>
    </workflow-progress>

    <section data-component="workflow-content">
        <form hx-post="<%= $next_step_url %>" hx-target="#workflow-container">
            <!-- Form fields -->
            <div class="htmx-indicator spinner"></div>
        </form>
    </section>

    <footer data-component="workflow-navigation">
        <button data-variant="outline" hx-get="<%= $prev_step_url %>">
            Previous
        </button>
        <button data-variant="primary" type="submit">
            Next Step
        </button>
    </footer>
</div>
```

#### HTMX Button Example
```html
<button class="cta-button"
        hx-post="/api/register"
        hx-target="#registration-form"
        hx-indicator="#spinner">
    Join Early Access
</button>
<div id="spinner" class="htmx-indicator spinner"></div>
```

## 12. Performance Considerations

1. **CSS Variables**: Use for dynamic theming without JavaScript overhead
2. **Animation Performance**: Use `transform` and `opacity` for GPU-accelerated animations
3. **Backdrop Filter**: May impact performance on lower-end devices, provide fallbacks
4. **Gradient Complexity**: Limit gradient stops for better rendering performance
5. **Font Loading**: Use system fonts to avoid external font loading delays