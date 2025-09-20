# ABOUTME: Workflow step to display admin dashboard overview with pending tasks and continuations
# ABOUTME: Loads dashboard data and prepares it for template rendering
use 5.40.2;
use Object::Pad;

require Registry::DAO::WorkflowStep;

class Registry::DAO::WorkflowSteps::AdminDashboardOverview :isa(Registry::DAO::WorkflowStep) {
    use Carp qw(confess);

    method process ($db, $data) {
        # Get current user from data
        my $user = $data->{current_user} or confess "current_user is required for admin dashboard";

        # Authorize admin access
        unless ($user->{role} =~ /^(admin|staff|instructor)$/) {
            confess "Unauthorized: admin role required";
        }

        # Get all dashboard data using AdminDashboard DAO
        require Registry::DAO::AdminDashboard;
        my $dashboard_data = Registry::DAO::AdminDashboard->get_admin_dashboard_data($db, $user);

        # Add user context
        $dashboard_data->{current_user} = $user;

        # Return data for template rendering
        return {
            status => 'success',
            template_data => $dashboard_data,
            next_step => 'task-selection'
        };
    }
}