# ABOUTME: Workflow step for collecting basic pricing plan information
# ABOUTME: Handles plan name, type, target audience, and scope configuration

use 5.40.2;
use utf8;
use experimental qw(try signatures);
use Object::Pad;

class Registry::DAO::WorkflowSteps::PricingPlanBasics :isa(Registry::DAO::WorkflowStep) {
    use Carp qw( croak );

    method process ($db, $form_data) {
        my $workflow = $self->workflow($db);
        my $run = $workflow->latest_run($db);

        # Validate required fields
        my @errors;
        push @errors, "Plan name is required" unless $form_data->{plan_name};
        push @errors, "Plan type is required" unless $form_data->{plan_type};
        push @errors, "Target audience is required" unless $form_data->{target_audience};
        push @errors, "Plan scope is required" unless $form_data->{plan_scope};

        if (@errors) {
            return {
                stay => 1,
                errors => \@errors
            };
        }

        # Validate plan name uniqueness globally
        # Since plans are now relationship-agnostic, ensure global uniqueness
        my $existing = Registry::DAO::PricingPlan->find($db, {
            plan_name => $form_data->{plan_name}
        });

        if ($existing) {
            return {
                stay => 1,
                errors => ["A pricing plan with this name already exists"]
            };
        }

        # Store plan basics in run data
        $run->update_data($db, {
            plan_basics => {
                plan_name => $form_data->{plan_name},
                plan_description => $form_data->{plan_description} || '',
                plan_type => $form_data->{plan_type},
                target_audience => $form_data->{target_audience},
                plan_scope => $form_data->{plan_scope},
            }
        });

        # Move to next step
        my $next_step = $self->next_step($db);
        return { next_step => $next_step ? $next_step->slug : undef };
    }

    method get_tenant_id($db, $run) {
        # Get tenant ID from session or run data
        my $data = $run->data || {};

        # Check if we have tenant context
        if ($data->{__tenant_slug} && $data->{__tenant_slug} ne 'registry') {
            require Registry::DAO::Tenant;
            my $tenant = Registry::DAO::Tenant->find($db, { slug => $data->{__tenant_slug} });
            return $tenant->id if $tenant;
        }

        # Default to platform tenant
        return '00000000-0000-0000-0000-000000000000';
    }

    method prepare_template_data($db, $run) {
        # Prepare data for template
        return {
            plan_types => [
                { value => 'subscription', label => 'Subscription', description => 'Recurring monthly or yearly billing' },
                { value => 'per_use', label => 'Per-Use', description => 'Pay only for what you use' },
                { value => 'hybrid', label => 'Hybrid', description => 'Base fee plus usage charges' },
                { value => 'one_time', label => 'One-Time', description => 'Single payment for access' },
            ],
            target_audiences => [
                { value => 'individual', label => 'Individual', description => 'Single user/student enrollment' },
                { value => 'family', label => 'Family', description => 'Family group enrollments' },
                { value => 'corporate', label => 'Corporate', description => 'Business/organization accounts' },
                { value => 'nonprofit', label => 'Non-Profit', description => 'Special pricing for nonprofits' },
            ],
            plan_scopes => [
                { value => 'customer', label => 'Customer', description => 'For your direct customers' },
                { value => 'tenant', label => 'Tenant', description => 'For other organizations using your platform' },
                { value => 'platform', label => 'Platform', description => 'Platform-wide pricing' },
            ]
        };
    }
}

1;