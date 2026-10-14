use 5.42.0;
use lib qw(lib);
use experimental qw(defer);
use Test::More import => [qw( done_testing is ok like unlike is_deeply subtest )];
defer { done_testing };

# Test that the workflow layout includes the progress component
subtest 'Workflow Layout Integration' => sub {
    # Read the workflow layout template
    my $layout_file = 'templates/layouts/workflow.html.ep';
    
    ok(-f $layout_file, 'Workflow layout template exists');
    
    open my $fh, '<', $layout_file or die "Cannot open $layout_file: $!";
    my $content = do { local $/; <$fh> };
    close $fh;
    
    # Check that the template includes the progress component
    like($content, qr/workflow-progress/, 'Layout includes workflow-progress component');
    like($content, qr/data-current-step/, 'Layout includes current step data attribute');
    like($content, qr/data-total-steps/, 'Layout includes total steps data attribute');
    like($content, qr/data-step-names/, 'Layout includes step names data attribute');
    like($content, qr/data-step-urls/, 'Layout includes step URLs data attribute');
    like($content, qr/data-completed-steps/, 'Layout includes completed steps data attribute');
    
    # Check that the component script is included
    like($content, qr/workflow-progress\.js/, 'Layout includes component script');
    
    # Check that HTMX is included for navigation
    like($content, qr/htmx\.org/, 'Layout includes HTMX for navigation');
    
    # The layout emits the element the script defines, and reads the stash key
    # the controller sets. Both halves matter: for most of this file's life the
    # assertion here was qr/if.*workflow_progress/, which matched the DEAD gate
    # `if (stash('show_workflow_progress'))` -- a key nothing ever set -- so it
    # passed while the indicator had never once rendered (#423).
    like($content, qr/<workflow-progress/,
        'Layout emits the custom element, not a div the component cannot claim');
    like($content, qr/stash\('workflow_progress'\)/,
        "Layout reads the stash key the controller actually sets");
    unlike($content, qr/show_workflow_progress/,
        'and not the gate nothing sets');

    # That it renders CONDITIONALLY, and on which condition, is asserted by
    # rendering the layout in t/controller/a-workflow-says-which-step-you-are-on.t.
    # Reading the source for an `if` cannot tell a live gate from a dead one,
    # which is how the old assertion here passed for so long.
};

subtest 'Web Component File Exists' => sub {
    my $component_file = 'public/js/components/workflow-progress.js';
    
    ok(-f $component_file, 'Workflow progress component file exists');
    
    # Check that the component file contains the expected class
    open my $fh, '<', $component_file or die "Cannot open $component_file: $!";
    my $content = do { local $/; <$fh> };
    close $fh;
    
    like($content, qr/class WorkflowProgress/, 'Component file contains WorkflowProgress class');
    like($content, qr/customElements\.define/, 'Component is registered as custom element');
    like($content, qr/workflow-progress/, 'Component has correct tag name');
    like($content, qr/attachShadow/, 'Component uses Shadow DOM');
    like($content, qr/HTMX/, 'Component integrates with HTMX');
};

subtest 'Test Templates Exist' => sub {
    my @test_templates = (
        'templates/test-workflow/step1.html.ep',
        'templates/test-workflow/step2.html.ep'
    );
    
    for my $template (@test_templates) {
        ok(-f $template, "Test template $template exists");
        
        # Check that test templates use the workflow layout
        open my $fh, '<', $template or die "Cannot open $template: $!";
        my $content = do { local $/; <$fh> };
        close $fh;
        
        like($content, qr/layout 'workflow'/, "Test template uses workflow layout");
    }
};