use 5.40.2;
use lib qw(lib);
use experimental qw(defer try);
use Test::More import => [qw( done_testing is ok like is_deeply subtest )];
defer { done_testing };

# Test that the workflow layout includes the progress component
subtest 'Workflow Layout Integration' => sub {
    # Read the workflow layout template
    my $layout_file = '/home/perigrin/dev/Registry/templates/layouts/workflow.html.ep';
    
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
    
    # Check that the progress component is conditionally rendered
    like($content, qr/if.*workflow_progress/, 'Progress component is conditionally rendered');
};

subtest 'Web Component File Exists' => sub {
    my $component_file = '/home/perigrin/dev/Registry/public/js/components/workflow-progress.js';
    
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
        '/home/perigrin/dev/Registry/templates/test-workflow/step1.html.ep',
        '/home/perigrin/dev/Registry/templates/test-workflow/step2.html.ep'
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