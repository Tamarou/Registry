use 5.40.2;
use lib qw(lib t/lib);
use experimental qw(defer try);
use Test::More import => [qw( done_testing is ok like is_deeply subtest )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;
use Test::Registry::Fixtures;

# Set up test data
my $dao = Registry::DAO->new( url => Test::Registry::DB->new_test_db() );
my $fixtures = Test::Registry::Fixtures->new( dao => $dao );

# Test the workflow progress functionality
subtest 'Workflow Progress Data Generation' => sub {
    # Create a test workflow with multiple steps
    my $workflow = $dao->create( Workflow => {
        slug => 'test-progress-workflow',
        name => 'Test Progress Workflow',
        description => 'Test workflow for progress indicator'
    });
    
    # Create workflow steps in specific order
    my $step1 = $dao->create( WorkflowStep => {
        workflow_id => $workflow->id,
        slug => 'landing',
        description => 'Welcome Step',
        class => 'Registry::DAO::WorkflowStep'
    });
    
    my $step2 = $dao->create( WorkflowStep => {
        workflow_id => $workflow->id,
        slug => 'profile',
        description => 'Profile Information',
        class => 'Registry::DAO::WorkflowStep'
    });
    
    my $step3 = $dao->create( WorkflowStep => {
        workflow_id => $workflow->id,
        slug => 'review',
        description => 'Review Details',
        class => 'Registry::DAO::WorkflowStep'
    });
    
    my $step4 = $dao->create( WorkflowStep => {
        workflow_id => $workflow->id,
        slug => 'complete',
        description => 'Completion',
        class => 'Registry::DAO::WorkflowStep'
    });
    
    # Create a workflow run
    my $run = $dao->create( WorkflowRun => {
        workflow_id => $workflow->id,
        latest_step_id => $step2->id,  # Currently on step 2
        data => { test_data => 'value' }
    });
    
    # Create a mock controller to test the progress method
    my $controller = MockWorkflowController->new(dao => $dao);
    
    # Test progress data for step 2 (current step)
    my $progress = $controller->_get_workflow_progress($run, $step2);
    
    is($progress->{current_step}, 2, 'Current step position is correct');
    is($progress->{total_steps}, 4, 'Total steps count is correct');
    
    my @step_names = split(',', $progress->{step_names});
    is_deeply(\@step_names, ['Welcome Step', 'Profile Information', 'Review Details', 'Completion'], 
        'Step names are correct');
    
    my @completed_steps = split(',', $progress->{completed_steps});
    is_deeply(\@completed_steps, ['1'], 'Completed steps are correct (only step 1)');
    
    # Test URLs are generated for completed steps only
    my @step_urls = split(',', $progress->{step_urls}, -1);
    ok($step_urls[0], 'URL generated for completed step 1');
    is($step_urls[1], '', 'No URL for current step 2');
    is($step_urls[2], '', 'No URL for future step 3');
    is($step_urls[3], '', 'No URL for future step 4');
};

subtest 'Step Name Generation' => sub {
    my $controller = MockWorkflowController->new(dao => $dao);
    
    # Test slug to name conversion
    is($controller->_generate_step_name('profile-setup'), 'Profile Setup', 
        'Converts hyphenated slug to title case');
    is($controller->_generate_step_name('landing'), 'Landing', 
        'Converts single word slug to title case');
    is($controller->_generate_step_name('multi-word-step-name'), 'Multi Word Step Name', 
        'Converts multi-word slug correctly');
};

subtest 'Progress with Auto-generated Step Names' => sub {
    # Create workflow with steps that have auto-generated descriptions
    my $workflow = $dao->create( Workflow => {
        slug => 'auto-name-workflow',
        name => 'Auto Name Workflow',
        description => 'Workflow with auto-generated step names',
    });
    
    my $step1 = $dao->create( WorkflowStep => {
        workflow_id => $workflow->id,
        slug => 'user-registration',
        description => 'Auto-created first step',  # Should be replaced
        
        class => 'Registry::DAO::WorkflowStep'
    });
    
    my $step2 = $dao->create( WorkflowStep => {
        workflow_id => $workflow->id,
        slug => 'payment-info',
        description => undef,  # No description
        
        class => 'Registry::DAO::WorkflowStep'
    });
    
    my $run = $dao->create( WorkflowRun => {
        workflow_id => $workflow->id,
        latest_step_id => $step1->id,
        data => {}
    });
    
    my $controller = MockWorkflowController->new(dao => $dao);
    my $progress = $controller->_get_workflow_progress($run, $step1);
    
    my @step_names = split(',', $progress->{step_names});
    is($step_names[0], 'User Registration', 'Auto-generated name from slug for step 1');
    is($step_names[1], 'Payment Info', 'Auto-generated name from slug for step 2');
};

subtest 'Progress with No Steps' => sub {
    # Create workflow with no steps
    my $workflow = $dao->create( Workflow => {
        slug => 'empty-workflow',
        name => 'Empty Workflow',
        description => 'Workflow with no steps',
    });
    
    my $run = $dao->create( WorkflowRun => {
        workflow_id => $workflow->id,
        latest_step_id => undef,
        data => {}
    });
    
    my $controller = MockWorkflowController->new(dao => $dao);
    my $progress = $controller->_get_workflow_progress($run, undef);
    
    is_deeply($progress, {}, 'Returns empty hash for workflow with no steps');
};

subtest 'Progress with Different Current Step Positions' => sub {
    # Create workflow for position testing
    my $workflow = $dao->create( Workflow => {
        slug => 'position-test-workflow',
        name => 'Position Test Workflow',
        description => 'Test different step positions',
    });
    
    my @steps;
    for my $i (1..5) {
        push @steps, $dao->create( WorkflowStep => {
            workflow_id => $workflow->id,
            slug => "step-$i",
            description => "Step $i",
            
            class => 'Registry::DAO::WorkflowStep'
        });
    }
    
    my $controller = MockWorkflowController->new(dao => $dao);
    
    # Test being on first step
    my $run1 = $dao->create( WorkflowRun => {
        workflow_id => $workflow->id,
        latest_step_id => $steps[0]->id,
        data => {}
    });
    
    my $progress1 = $controller->_get_workflow_progress($run1, $steps[0]);
    is($progress1->{current_step}, 1, 'First step position correct');
    is($progress1->{completed_steps}, '', 'No completed steps when on first step');
    
    # Test being on middle step
    my $run3 = $dao->create( WorkflowRun => {
        workflow_id => $workflow->id,
        latest_step_id => $steps[2]->id,
        data => {}
    });
    
    my $progress3 = $controller->_get_workflow_progress($run3, $steps[2]);
    is($progress3->{current_step}, 3, 'Middle step position correct');
    is($progress3->{completed_steps}, '1,2', 'Previous steps marked as completed');
    
    # Test being on last step
    my $run5 = $dao->create( WorkflowRun => {
        workflow_id => $workflow->id,
        latest_step_id => $steps[4]->id,
        data => {}
    });
    
    my $progress5 = $controller->_get_workflow_progress($run5, $steps[4]);
    is($progress5->{current_step}, 5, 'Last step position correct');
    is($progress5->{completed_steps}, '1,2,3,4', 'All previous steps marked as completed');
};

subtest 'URL Generation for Navigation' => sub {
    # Test that URLs are generated correctly for backward navigation
    my $workflow = $dao->create( Workflow => {
        slug => 'url-test-workflow',
        name => 'URL Test Workflow',
        description => 'Test URL generation',
    });
    
    my $step1 = $dao->create( WorkflowStep => {
        workflow_id => $workflow->id,
        slug => 'start',
        description => 'Start Step',
        
        class => 'Registry::DAO::WorkflowStep'
    });
    
    my $step2 = $dao->create( WorkflowStep => {
        workflow_id => $workflow->id,
        slug => 'middle',
        description => 'Middle Step',
        
        class => 'Registry::DAO::WorkflowStep'
    });
    
    my $run = $dao->create( WorkflowRun => {
        workflow_id => $workflow->id,
        latest_step_id => $step2->id,
        data => {}
    });
    
    my $controller = MockWorkflowController->new(dao => $dao);
    my $progress = $controller->_get_workflow_progress($run, $step2);
    
    my @urls = split(',', $progress->{step_urls}, -1);
    like($urls[0], qr/url-test-workflow.*start/, 'URL contains workflow slug and step slug');
    is($urls[1], '', 'Current step has no URL');
};

# Mock controller class for testing
package MockWorkflowController {
    use Object::Pad;
    class MockWorkflowController {
        field $dao :param;
        
        method _get_workflow_progress($run, $current_step) {
            # Get all workflow steps in order
            my $workflow = $run->workflow($dao->db);
            my $steps = $dao->db->select(
                'workflow_steps',
                ['id', 'slug', 'description'],
                { workflow_id => $workflow->id },
                { -asc => 'created_at' }
            )->hashes->to_array;
            
            # If no explicit sort_order, fall back to creation order
            if (!@$steps) {
                $steps = $dao->db->select(
                    'workflow_steps',
                    ['id', 'slug', 'description'],
                    { workflow_id => $workflow->id },
                    { -asc => 'created_at' }
                )->hashes->to_array;
            }
            
            return {} unless @$steps;
            
            # Find current step position
            my $current_position = 1;
            my $current_step_id = $current_step ? $current_step->id : undef;
            
            for my $i (0 .. $#$steps) {
                if ($steps->[$i]{id} eq $current_step_id) {
                    $current_position = $i + 1;
                    last;
                }
            }
            
            # Generate step names and URLs
            my @step_names;
            my @step_urls;
            my @completed_steps;
            
            for my $i (0 .. $#$steps) {
                my $step = $steps->[$i];
                my $step_number = $i + 1;
                
                # Use description if available, otherwise generate from slug
                my $step_name = $step->{description};
                if (!$step_name || $step_name eq 'Auto-created first step' || $step_name eq 'Emergency auto-created step') {
                    $step_name = $self->_generate_step_name($step->{slug});
                }
                push @step_names, $step_name;
                
                # Generate URL for navigation (only for completed steps)
                my $step_url = '';
                if ($step_number < $current_position) {
                    # Mock URL generation
                    $step_url = "/${\$workflow->slug}/run/${\$run->id}/step/$step->{slug}";
                    push @completed_steps, $step_number;
                } elsif ($step_number == $current_position) {
                    # Current step - no URL needed
                    $step_url = '';
                } else {
                    # Future step - no URL
                    $step_url = '';
                }
                push @step_urls, $step_url;
            }
            
            return {
                current_step => $current_position,
                total_steps => scalar(@$steps),
                step_names => join(',', @step_names),
                step_urls => join(',', @step_urls),
                completed_steps => join(',', @completed_steps),
            };
        }
        
        method _generate_step_name($slug) {
            # Convert slug to human-readable name
            my $name = $slug;
            $name =~ s/-/ /g;
            $name =~ s/\b(\w)/\u$1/g;  # Title case
            return $name;
        }
    }
}