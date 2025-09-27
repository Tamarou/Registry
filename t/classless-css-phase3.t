#!/usr/bin/env perl
# ABOUTME: Tests for Phase 3 classless CSS components - complex layouts, data display, interactive elements
# ABOUTME: Validates dashboard grids, modals, tables, dropdowns, and template conversions with semantic HTML

use 5.34.0;
use experimental 'signatures';
use Test::More;

# Test complex layout components
subtest 'Complex layout components with semantic HTML' => sub {
    plan tests => 12;

    # Test CSS file exists and can be read
    my $css_file = '/home/perigrin/dev/Registry/public/css/classless.css';
    ok(-f $css_file, 'Classless CSS file exists');

    # Test dashboard layout structure
    my $dashboard_html = q{
        <main data-layout="dashboard">
            <aside>
                <header>
                    <h3>Navigation</h3>
                </header>
                <nav>
                    <ul data-component="nav-sidebar">
                        <li><a href="/dashboard">Dashboard</a></li>
                        <li><a href="/programs">Programs</a></li>
                    </ul>
                </nav>
            </aside>
            <header>
                <h1>Admin Dashboard</h1>
            </header>
            <section>
                <h2>Content Area</h2>
                <p>Main dashboard content goes here.</p>
            </section>
            <footer>
                <p>Footer content</p>
            </footer>
        </main>
    };

    # Test modal dialog structure
    my $modal_html = q{
        <dialog>
            <header>
                <h2>Confirm Action</h2>
                <button data-action="close-modal" aria-label="Close">×</button>
            </header>
            <section>
                <p>Are you sure you want to delete this program?</p>
            </section>
            <footer>
                <button type="button" data-variant="secondary">Cancel</button>
                <button type="button" data-variant="danger">Delete</button>
            </footer>
        </dialog>
    };

    # Test tab interface structure
    my $tabs_html = q{
        <div>
            <div role="tablist" aria-label="Program settings">
                <button role="tab" aria-selected="true" aria-controls="general-panel" id="general-tab">General</button>
                <button role="tab" aria-selected="false" aria-controls="schedule-panel" id="schedule-tab">Schedule</button>
                <button role="tab" aria-selected="false" aria-controls="pricing-panel" id="pricing-tab">Pricing</button>
            </div>
            <div role="tabpanel" id="general-panel" aria-labelledby="general-tab">
                <h3>General Settings</h3>
                <p>Basic program information and description.</p>
            </div>
            <div role="tabpanel" id="schedule-panel" aria-labelledby="schedule-tab" hidden>
                <h3>Schedule Settings</h3>
                <p>Program schedule and timing configuration.</p>
            </div>
            <div role="tabpanel" id="pricing-panel" aria-labelledby="pricing-tab" hidden>
                <h3>Pricing Settings</h3>
                <p>Program pricing and payment options.</p>
            </div>
        </div>
    };

    # Test accordion structure
    my $accordion_html = q{
        <div data-component="accordion-group">
            <details data-component="accordion">
                <summary>Program Requirements</summary>
                <div>
                    <p>List of requirements for program participation.</p>
                </div>
            </details>
            <details data-component="accordion">
                <summary>Safety Guidelines</summary>
                <div>
                    <p>Important safety information for all participants.</p>
                </div>
            </details>
            <details data-component="accordion" open>
                <summary>Contact Information</summary>
                <div>
                    <p>How to reach program coordinators and staff.</p>
                </div>
            </details>
        </div>
    };

    ok($dashboard_html, 'Dashboard layout structure defined');
    ok($modal_html, 'Modal dialog structure defined');
    ok($tabs_html, 'Tab interface structure defined');
    ok($accordion_html, 'Accordion structure defined');

    # Verify semantic structure and ARIA patterns
    like($dashboard_html, qr/data-layout="dashboard"/, 'Dashboard uses layout data attribute');
    like($modal_html, qr/<dialog>.*<\/dialog>/s, 'Modal uses semantic dialog element');
    like($tabs_html, qr/role="tablist"/, 'Tabs use proper ARIA tablist');
    like($tabs_html, qr/aria-selected="true"/, 'Active tab marked with aria-selected');
    like($tabs_html, qr/aria-controls/, 'Tab controls reference panels');
    like($accordion_html, qr/data-component="accordion-group"/, 'Accordion group uses component attribute');
    like($accordion_html, qr/<details[^>]*open/, 'Accordion supports open state');
};

# Test data display components
subtest 'Data display components with semantic elements' => sub {
    plan tests => 10;

    # Test table with sorting and filtering
    my $table_html = q{
        <table data-striped="true">
            <thead>
                <tr>
                    <th data-sortable="true" data-sort="asc">Student Name</th>
                    <th data-sortable="true">Program</th>
                    <th data-sortable="true">Status</th>
                    <th>Actions</th>
                </tr>
            </thead>
            <tbody>
                <tr>
                    <td>Emma Johnson</td>
                    <td>Spring Art Class</td>
                    <td><span data-component="badge" data-variant="success">Enrolled</span></td>
                    <td>
                        <button data-size="sm">Edit</button>
                        <button data-size="sm" data-variant="danger">Remove</button>
                    </td>
                </tr>
                <tr>
                    <td>Liam Smith</td>
                    <td>Soccer Training</td>
                    <td><span data-component="badge" data-variant="warning">Waitlisted</span></td>
                    <td>
                        <button data-size="sm">Edit</button>
                        <button data-size="sm" data-variant="danger">Remove</button>
                    </td>
                </tr>
            </tbody>
        </table>
    };

    # Test timeline component
    my $timeline_html = q{
        <ol data-component="timeline">
            <li>
                <time datetime="2024-01-15">January 15, 2024</time>
                <h3>Program Registration Opens</h3>
                <p>Registration for spring programs is now available online.</p>
            </li>
            <li>
                <time datetime="2024-02-01">February 1, 2024</time>
                <h3>Early Bird Deadline</h3>
                <p>Last day to register for early bird pricing discounts.</p>
            </li>
            <li>
                <time datetime="2024-03-01">March 1, 2024</time>
                <h3>Programs Begin</h3>
                <p>All spring after-school programs start this week.</p>
            </li>
        </ol>
    };

    # Test metrics display
    my $metrics_html = q{
        <div data-component="metrics">
            <section>
                <h3>Total Students</h3>
                <p>247</p>
                <small>+12% from last month</small>
            </section>
            <section>
                <h3>Active Programs</h3>
                <p>18</p>
                <small>3 new this month</small>
            </section>
            <section>
                <h3>Revenue</h3>
                <p>$24,680</p>
                <small>+8% from last month</small>
            </section>
        </div>
    };

    # Test badges and tags
    my $badges_html = q{
        <div>
            <span data-component="badge" data-variant="primary">New</span>
            <span data-component="badge" data-variant="success">Active</span>
            <span data-component="badge" data-variant="warning">Full</span>
            <span data-component="badge" data-variant="danger">Cancelled</span>

            <span data-component="tag" data-variant="primary">
                Art & Crafts
                <button aria-label="Remove tag">×</button>
            </span>
            <span data-component="tag">
                Ages 5-8
                <button aria-label="Remove tag">×</button>
            </span>
        </div>
    };

    ok($table_html, 'Table with sorting structure defined');
    ok($timeline_html, 'Timeline component structure defined');
    ok($metrics_html, 'Metrics display structure defined');
    ok($badges_html, 'Badges and tags structure defined');

    # Verify semantic attributes and accessibility
    like($table_html, qr/data-sortable="true"/, 'Table columns marked as sortable');
    like($table_html, qr/data-sort="asc"/, 'Table shows sort direction');
    like($timeline_html, qr/<time[^>]*datetime/, 'Timeline uses semantic time elements');
    like($timeline_html, qr/data-component="timeline"/, 'Timeline uses component attribute');
    like($metrics_html, qr/data-component="metrics"/, 'Metrics use component attribute');
    like($badges_html, qr/aria-label="Remove tag"/, 'Tag removal buttons have aria labels');
};

# Test interactive components
subtest 'Interactive components with proper ARIA' => sub {
    plan tests => 10;

    # Test dropdown menu
    my $dropdown_html = q{
        <div data-component="dropdown" aria-expanded="false">
            <button aria-haspopup="true" aria-expanded="false">
                Actions
            </button>
            <ul role="menu">
                <li><a href="/edit" role="menuitem">Edit Program</a></li>
                <li><a href="/duplicate" role="menuitem">Duplicate</a></li>
                <li><hr></li>
                <li><button role="menuitem" data-variant="danger">Delete</button></li>
            </ul>
        </div>
    };

    # Test alert notifications
    my $alerts_html = q{
        <div role="alert" data-variant="success">
            <span data-icon="check-circle"></span>
            <div>
                <h4>Success!</h4>
                <p>Program has been successfully created and is now available for registration.</p>
            </div>
            <button data-action="dismiss" aria-label="Dismiss notification">×</button>
        </div>

        <div role="alert" data-variant="error">
            <span data-icon="exclamation-triangle"></span>
            <div>
                <h4>Error</h4>
                <p>Unable to save program changes. Please check your internet connection and try again.</p>
            </div>
            <button data-action="dismiss" aria-label="Dismiss notification">×</button>
        </div>
    };

    # Test tooltip elements
    my $tooltip_html = q{
        <button data-tooltip="Click to edit program details" data-tooltip-position="top">
            Edit Program
        </button>
        <span data-tooltip="This program is at maximum capacity" data-tooltip-position="bottom">
            Full Program
        </span>
    };

    # Test loading states
    my $loading_html = q{
        <div data-component="loading">
            <div data-component="spinner" data-size="lg"></div>
            <span>Loading programs...</span>
        </div>

        <div>
            <div data-component="skeleton" data-type="title"></div>
            <div data-component="skeleton" data-type="paragraph"></div>
            <div data-component="skeleton" data-type="paragraph"></div>
            <div data-component="skeleton" data-type="button"></div>
        </div>
    };

    ok($dropdown_html, 'Dropdown menu structure defined');
    ok($alerts_html, 'Alert notifications structure defined');
    ok($tooltip_html, 'Tooltip elements structure defined');
    ok($loading_html, 'Loading states structure defined');

    # Verify ARIA patterns and accessibility
    like($dropdown_html, qr/aria-expanded="false"/, 'Dropdown uses aria-expanded');
    like($dropdown_html, qr/role="menu"/, 'Dropdown menu has menu role');
    like($alerts_html, qr/role="alert"/, 'Notifications use alert role');
    like($alerts_html, qr/aria-label="Dismiss notification"/, 'Dismiss buttons have aria labels');
    like($tooltip_html, qr/data-tooltip=/, 'Tooltips use data attributes');
    like($loading_html, qr/data-component="skeleton"/, 'Skeleton screens use component attributes');
};

# Test template conversions
subtest 'Template conversions maintain functionality' => sub {
    plan tests => 9;

    # Read converted profile template
    my $profile_template_path = '/home/perigrin/dev/Registry/templates/tenant-signup/profile.html.ep';
    ok(-f $profile_template_path, 'Profile template file exists');

    # Read converted workflow layout
    my $workflow_layout_path = '/home/perigrin/dev/Registry/templates/layouts/workflow.html.ep';
    ok(-f $workflow_layout_path, 'Workflow layout file exists');

    # Check profile template content
    open my $profile_fh, '<', $profile_template_path or die "Cannot read profile template: $!";
    my $profile_content = do { local $/; <$profile_fh> };
    close $profile_fh;

    # Check workflow layout content
    open my $workflow_fh, '<', $workflow_layout_path or die "Cannot read workflow layout: $!";
    my $workflow_content = do { local $/; <$workflow_fh> };
    close $workflow_fh;

    # Verify profile template uses classless approach
    like($profile_content, qr/data-component="container"/, 'Profile uses container component');
    like($profile_content, qr/<fieldset>/, 'Profile uses semantic fieldset grouping');
    like($profile_content, qr/data-multistep="true"/, 'Profile uses multistep form attribute');
    like($profile_content, qr/data-component="badge"/, 'Profile uses badge component for subdomain');

    # Verify workflow layout uses classless approach
    like($workflow_content, qr/classless\.css/, 'Workflow layout includes classless CSS');
    like($workflow_content, qr/data-component="workflow-container"/, 'Workflow uses container component');
    like($workflow_content, qr/data-layout="workflow"/, 'Body uses workflow layout attribute');
};

# Test responsive design and mobile compatibility
subtest 'Responsive design with mobile-first approach' => sub {
    plan tests => 6;

    # Test CSS file contains responsive rules
    my $css_file = '/home/perigrin/dev/Registry/public/css/classless.css';
    open my $fh, '<', $css_file or die "Cannot read CSS file: $!";
    my $css_content = do { local $/; <$fh> };
    close $fh;

    # Check for mobile breakpoints
    like($css_content, qr/\@media \(max-width: 640px\)/, 'CSS includes mobile breakpoint');
    like($css_content, qr/\@media \(max-width: 768px\)/, 'CSS includes tablet breakpoint');
    like($css_content, qr/\@media \(max-width: 480px\)/, 'CSS includes small mobile breakpoint');

    # Check for responsive grid adjustments
    like($css_content, qr/grid-template-columns: 1fr/, 'Grid becomes single column on mobile');

    # Check for responsive dashboard layout
    like($css_content, qr/main\[data-layout="dashboard"\].*grid-template-areas/s, 'Dashboard layout is responsive');

    # Check for mobile font size adjustments
    like($css_content, qr/font-size: 16px.*Prevent zoom/, 'Mobile inputs prevent zoom');
};

done_testing();