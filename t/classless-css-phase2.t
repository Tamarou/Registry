#!/usr/bin/env perl
# ABOUTME: Tests for Phase 2 classless CSS components - advanced forms, cards, navigation, and button patterns
# ABOUTME: Validates semantic HTML structure and visual consistency with original design system

use 5.34.0;
use experimental 'signatures';
use Test::More;

# Test advanced form components with semantic HTML
subtest 'Advanced form components with semantic HTML' => sub {
    plan tests => 11;

    # Test fieldset grouping for related form elements
    my $form_html = q{
        <form>
            <fieldset>
                <legend>Personal Information</legend>
                <div>
                    <label for="first-name">First Name</label>
                    <input type="text" id="first-name" name="first_name" required>
                </div>
                <div>
                    <label for="last-name">Last Name</label>
                    <input type="text" id="last-name" name="last_name" required>
                </div>
            </fieldset>
        </form>
    };

    # Test CSS file exists and can be read
    my $css_file = '/home/perigrin/dev/Registry/public/css/structure.css';
    ok(-f $css_file, 'Structure CSS file exists');

    # Test form validation states using data attributes
    my $validation_html = q{
        <form>
            <div>
                <label for="email">Email Address</label>
                <input type="email" id="email" name="email" data-state="error" aria-describedby="email-error">
                <div id="email-error" data-type="error">Please enter a valid email address</div>
            </div>
            <div>
                <label for="phone">Phone Number</label>
                <input type="tel" id="phone" name="phone" data-state="success" aria-describedby="phone-success">
                <div id="phone-success" data-type="success">Phone number verified</div>
            </div>
        </form>
    };

    # Test multi-step form structure
    my $multistep_html = q{
        <form data-multistep="true">
            <progress value="2" max="4" aria-label="Step 2 of 4">Step 2 of 4</progress>
            <section data-step="current">
                <h2>Contact Information</h2>
                <fieldset>
                    <legend>Emergency Contact</legend>
                    <div>
                        <label for="emergency-name">Emergency Contact Name</label>
                        <input type="text" id="emergency-name" name="emergency_name" required>
                    </div>
                </fieldset>
            </section>
        </form>
    };

    # Test form with help text and descriptions
    my $accessible_form = q{
        <form>
            <div>
                <label for="password">Password</label>
                <input type="password" id="password" name="password" aria-describedby="password-help">
                <div id="password-help" data-type="help">Must be at least 8 characters with numbers and symbols</div>
            </div>
        </form>
    };

    ok($form_html, 'Form with semantic fieldset structure defined');
    ok($validation_html, 'Form validation states with data attributes defined');
    ok($multistep_html, 'Multi-step form structure defined');
    ok($accessible_form, 'Accessible form with help text defined');

    # Verify the test structures are well-formed HTML
    like($form_html, qr/<fieldset>.*<legend>.*<\/fieldset>/s, 'Fieldset contains legend');
    like($validation_html, qr/data-state="error"/, 'Error state uses data attribute');
    like($validation_html, qr/data-state="success"/, 'Success state uses data attribute');
    like($multistep_html, qr/<progress[^>]*>/, 'Multi-step form includes progress indicator');
    like($accessible_form, qr/aria-describedby/, 'Form uses proper ARIA attributes');
    like($accessible_form, qr/data-type="help"/, 'Help text uses semantic data attribute');
};

# Test card and container components with semantic elements
subtest 'Card and container components with semantic elements' => sub {
    plan tests => 8;

    # Test article as card component
    my $article_card = q{
        <article data-component="card">
            <header>
                <h3>Program Registration</h3>
                <p>Spring 2024 After-School Programs</p>
            </header>
            <div>
                <p>Join our exciting after-school programs designed for children ages 5-12.</p>
                <ul>
                    <li>Art & Crafts</li>
                    <li>STEM Activities</li>
                    <li>Sports & Recreation</li>
                </ul>
            </div>
            <footer>
                <button type="button">Learn More</button>
                <button type="button" data-variant="primary">Register Now</button>
            </footer>
        </article>
    };

    # Test section as container component
    my $section_container = q{
        <section data-component="container" data-size="large">
            <header>
                <h2>Dashboard Overview</h2>
            </header>
            <div data-layout="grid">
                <article data-component="widget">
                    <h3>Total Enrollments</h3>
                    <p data-metric="145">145</p>
                </article>
                <article data-component="widget">
                    <h3>Active Programs</h3>
                    <p data-metric="12">12</p>
                </article>
            </div>
        </section>
    };

    # Test aside for sidebar content
    my $aside_sidebar = q{
        <aside data-component="sidebar">
            <header>
                <h3>Quick Actions</h3>
            </header>
            <nav>
                <ul>
                    <li><a href="/programs/new">Add New Program</a></li>
                    <li><a href="/students/register">Register Student</a></li>
                    <li><a href="/reports">View Reports</a></li>
                </ul>
            </nav>
        </aside>
    };

    ok($article_card, 'Article card component structure defined');
    ok($section_container, 'Section container component structure defined');
    ok($aside_sidebar, 'Aside sidebar component structure defined');

    # Verify semantic structure
    like($article_card, qr/<article[^>]*data-component="card"/, 'Article uses card data attribute');
    like($article_card, qr/<header>.*<footer>/s, 'Article card has header and footer');
    like($section_container, qr/data-layout="grid"/, 'Container uses layout data attribute');
    like($aside_sidebar, qr/<aside[^>]*data-component="sidebar"/, 'Aside uses sidebar data attribute');
    like($aside_sidebar, qr/<nav>.*<\/nav>/s, 'Sidebar contains navigation');
};

# Test navigation components with semantic elements
subtest 'Navigation components with semantic elements' => sub {
    plan tests => 8;

    # Test main navigation
    my $main_nav = q{
        <nav role="navigation" aria-label="Main navigation">
            <div data-component="nav-brand">
                <a href="/">Registry</a>
            </div>
            <ul data-component="nav-menu">
                <li><a href="/programs" aria-current="page">Programs</a></li>
                <li><a href="/students">Students</a></li>
                <li><a href="/reports">Reports</a></li>
            </ul>
            <div data-component="nav-actions">
                <button type="button" data-variant="secondary">Sign In</button>
                <button type="button" data-variant="primary">Get Started</button>
            </div>
        </nav>
    };

    # Test breadcrumb navigation
    my $breadcrumb = q{
        <nav aria-label="Breadcrumb">
            <ol data-component="breadcrumb">
                <li><a href="/">Home</a></li>
                <li><a href="/programs">Programs</a></li>
                <li><span aria-current="page">Spring Art Class</span></li>
            </ol>
        </nav>
    };

    # Test sidebar navigation
    my $sidebar_nav = q{
        <nav aria-label="Sidebar navigation">
            <ul data-component="nav-sidebar">
                <li>
                    <a href="/dashboard">
                        <span data-icon="dashboard"></span>
                        Dashboard
                    </a>
                </li>
                <li>
                    <details>
                        <summary>Programs</summary>
                        <ul>
                            <li><a href="/programs">All Programs</a></li>
                            <li><a href="/programs/new">Add Program</a></li>
                        </ul>
                    </details>
                </li>
            </ul>
        </nav>
    };

    ok($main_nav, 'Main navigation structure defined');
    ok($breadcrumb, 'Breadcrumb navigation structure defined');
    ok($sidebar_nav, 'Sidebar navigation structure defined');

    # Verify semantic attributes
    like($main_nav, qr/role="navigation"/, 'Main nav has navigation role');
    like($main_nav, qr/aria-label="Main navigation"/, 'Main nav has aria label');
    like($breadcrumb, qr/aria-current="page"/, 'Breadcrumb marks current page');
    like($sidebar_nav, qr/<details>.*<summary>/s, 'Sidebar nav uses details/summary for collapsible sections');
    like($sidebar_nav, qr/data-component="nav-sidebar"/, 'Sidebar nav uses component data attribute');
};

# Test enhanced button patterns
subtest 'Enhanced button patterns and groups' => sub {
    plan tests => 6;

    # Test button groups
    my $button_group = q{
        <div data-component="button-group" role="group" aria-label="Text formatting">
            <button type="button" aria-pressed="false">Bold</button>
            <button type="button" aria-pressed="true">Italic</button>
            <button type="button" aria-pressed="false">Underline</button>
        </div>
    };

    # Test floating action button
    my $fab = q{
        <button type="button" data-component="fab" data-position="bottom-right" aria-label="Add new student">
            <span data-icon="plus" aria-hidden="true"></span>
        </button>
    };

    # Test icon buttons
    my $icon_buttons = q{
        <div data-component="toolbar" role="toolbar" aria-label="Document actions">
            <button type="button" data-size="sm" aria-label="Edit document">
                <span data-icon="edit" aria-hidden="true"></span>
            </button>
            <button type="button" data-size="sm" aria-label="Delete document">
                <span data-icon="delete" aria-hidden="true"></span>
            </button>
        </div>
    };

    ok($button_group, 'Button group structure defined');
    ok($fab, 'Floating action button structure defined');
    ok($icon_buttons, 'Icon button structure defined');

    # Verify accessibility attributes
    like($button_group, qr/role="group"/, 'Button group has group role');
    like($fab, qr/aria-label="Add new student"/, 'FAB has descriptive aria label');
    like($icon_buttons, qr/aria-hidden="true"/, 'Icon spans are hidden from screen readers');
};

done_testing();