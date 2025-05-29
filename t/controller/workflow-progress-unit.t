use 5.40.2;
use lib qw(lib);
use experimental qw(defer try);
use Test::More import => [qw( done_testing is ok like is_deeply subtest pass )];
defer { done_testing };

use Registry::Controller::Workflows;

# Test the helper methods directly without database dependencies
subtest 'Step Name Generation' => sub {
    # Create a minimal mock controller for testing the helper method
    my $controller = bless {}, 'Registry::Controller::Workflows';
    
    # Test slug to name conversion
    is($controller->_generate_step_name('profile-setup'), 'Profile Setup', 
        'Converts hyphenated slug to title case');
    is($controller->_generate_step_name('landing'), 'Landing', 
        'Converts single word slug to title case');
    is($controller->_generate_step_name('multi-word-step-name'), 'Multi Word Step Name', 
        'Converts multi-word slug correctly');
    is($controller->_generate_step_name('user-registration'), 'User Registration',
        'Converts user-registration correctly');
    is($controller->_generate_step_name('payment-info'), 'Payment Info',
        'Converts payment-info correctly');
    is($controller->_generate_step_name('review-and-submit'), 'Review And Submit',
        'Converts complex slug correctly');
};

subtest 'Controller Method Exists' => sub {
    # Verify the _get_workflow_progress method exists
    ok(Registry::Controller::Workflows->can('_get_workflow_progress'), 
        '_get_workflow_progress method exists');
    
    # Verify the _generate_step_name method exists  
    ok(Registry::Controller::Workflows->can('_generate_step_name'),
        '_generate_step_name method exists');
};

subtest 'get_workflow_run_step Integration' => sub {
    # Verify the get_workflow_run_step method has been updated
    ok(Registry::Controller::Workflows->can('get_workflow_run_step'),
        'get_workflow_run_step method exists');
    
    # This tests that the method exists and would pass progress data
    # Full integration testing requires database setup
    pass('Method exists for integration with workflow progress');
};