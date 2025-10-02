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

## 11. Integration with Registry Application

To integrate this design system into the existing Registry Mojolicious templates:

1. **Extract CSS into separate file**: Create `/public/css/design-system.css`
2. **Update base layout**: Modify `templates/layouts/default.html.ep` to include design system CSS
3. **Apply component classes**: Update existing templates to use the design system classes
4. **Maintain HTMX compatibility**: Ensure animations don't interfere with HTMX transitions
5. **Progressive enhancement**: Apply effects that degrade gracefully for older browsers

### Template Integration Example
```perl
# In templates/layouts/default.html.ep
<link rel="stylesheet" href="/css/design-system.css">

# In templates/index.html.ep
<button class="cta-button" hx-post="/api/register">
    Join Early Access
</button>
```

## 12. Performance Considerations

1. **CSS Variables**: Use for dynamic theming without JavaScript overhead
2. **Animation Performance**: Use `transform` and `opacity` for GPU-accelerated animations
3. **Backdrop Filter**: May impact performance on lower-end devices, provide fallbacks
4. **Gradient Complexity**: Limit gradient stops for better rendering performance
5. **Font Loading**: Use system fonts to avoid external font loading delays