# ABOUTME: Workflow step for reviewing and activating the pricing plan
# ABOUTME: Creates the plan in the database and sets activation parameters

use 5.40.2;
use utf8;
use experimental qw(try signatures);
use Object::Pad;

class Registry::DAO::WorkflowSteps::ReviewActivatePlan :isa(Registry::DAO::WorkflowStep) {
    use Carp qw( croak );
    use DateTime;
    use Registry::DAO::PricingPlan;

    method process ($db, $form_data) {
        my $workflow = $self->workflow($db);
        my $run = $workflow->latest_run($db);

        # Get all collected data
        my $data = $run->data || {};
        my $plan_basics = $data->{plan_basics} || {};
        my $pricing_model = $data->{pricing_model} || {};
        my $resource_allocation = $data->{resource_allocation} || {};
        my $requirements_rules = $data->{requirements_rules} || {};

        # Handle review actions
        my $action = $form_data->{action} || '';

        if ($action eq 'back') {
            # Go back to previous step
            return { next_step => 'requirements-rules' };
        }
        elsif ($action eq 'save_draft') {
            # Save as draft (inactive)
            return $self->create_plan($db, $run, $data, {
                is_active => 0,
                activation_date => undef,
                draft => 1
            });
        }
        elsif ($action eq 'activate') {
            # Validate activation date if provided
            my $activation_date = $form_data->{activation_date};
            if ($activation_date) {
                try {
                    my $dt = DateTime->new(
                        year => substr($activation_date, 0, 4),
                        month => substr($activation_date, 5, 2),
                        day => substr($activation_date, 8, 2),
                    );

                    # Check if date is in the future
                    if ($dt < DateTime->now) {
                        return {
                            stay => 1,
                            errors => ["Activation date must be in the future"]
                        };
                    }
                }
                catch ($e) {
                    return {
                        stay => 1,
                        errors => ["Invalid activation date format"]
                    };
                }
            }

            # Create and activate the plan
            return $self->create_plan($db, $run, $data, {
                is_active => $activation_date ? 0 : 1, # Active immediately if no date specified
                activation_date => $activation_date,
                draft => 0,
                requires_approval => $form_data->{requires_approval} eq 'yes' ? 1 : 0,
            });
        }
        else {
            # Show review page
            return { stay => 1 };
        }
    }

    method create_plan($db, $run, $data, $options) {
        my $plan_basics = $data->{plan_basics} || {};
        my $pricing_model = $data->{pricing_model} || {};
        my $resource_allocation = $data->{resource_allocation} || {};
        my $requirements_rules = $data->{requirements_rules} || {};

        # Merge resource allocation and quotas into pricing_configuration
        my $pricing_configuration = $pricing_model->{pricing_configuration} || {};
        $pricing_configuration->{resources} = $resource_allocation->{resources} || {};
        $pricing_configuration->{quotas} = $resource_allocation->{quotas} || {};

        # Merge requirements into the requirements field
        my $requirements = $requirements_rules->{requirements} || {};
        my $rules = $requirements_rules->{rules} || {};

        # Add rules to pricing configuration
        $pricing_configuration->{rules} = $rules;

        # Create the pricing plan
        my $plan;
        try {
            $plan = Registry::DAO::PricingPlan->create($db, {
                offering_tenant_id => $plan_basics->{offering_tenant_id},
                plan_scope => $plan_basics->{plan_scope},
                plan_name => $plan_basics->{plan_name},
                plan_type => $plan_basics->{plan_type},
                pricing_model_type => $pricing_model->{pricing_model_type},
                amount => $pricing_model->{amount} || 0,
                currency => $pricing_model->{currency},
                installments_allowed => $pricing_model->{installments_allowed} ? 1 : 0,
                installment_count => $pricing_model->{installment_count},
                requirements => $requirements,
                pricing_configuration => $pricing_configuration,
                metadata => {
                    description => $plan_basics->{plan_description},
                    target_audience => $plan_basics->{target_audience},
                    is_active => $options->{is_active},
                    activation_date => $options->{activation_date},
                    draft => $options->{draft},
                    requires_approval => $options->{requires_approval},
                    created_by_workflow => $self->workflow($db)->id,
                    created_by_run => $run->id,
                }
            });
        }
        catch ($e) {
            return {
                stay => 1,
                errors => ["Failed to create pricing plan: $e"]
            };
        }

        # Record creation event for audit trail
        if ($plan) {
            # Store plan ID in run data for confirmation
            $run->update_data($db, {
                %$data,
                created_plan_id => $plan->id,
                completed => 1
            });

            # Mark workflow as completed
            $run->complete($db);

            return {
                completed => 1,
                plan_id => $plan->id,
                template => 'pricing-plan-creation/complete',
            };
        }

        # This shouldn't happen but handle gracefully
        return {
            stay => 1,
            errors => ["Failed to create pricing plan"]
        };
    }

    method prepare_template_data ($db, $run) {
        my $data = $run->data || {};
        my $plan_basics = $data->{plan_basics} || {};
        my $pricing_model = $data->{pricing_model} || {};
        my $resource_allocation = $data->{resource_allocation} || {};
        my $requirements_rules = $data->{requirements_rules} || {};

        # Format the plan summary for review
        my $summary = {
            # Basic Information
            plan_name => $plan_basics->{plan_name},
            plan_description => $plan_basics->{plan_description},
            plan_type => $plan_basics->{plan_type},
            target_audience => $plan_basics->{target_audience},
            plan_scope => $plan_basics->{plan_scope},

            # Pricing Model
            pricing_model_type => $pricing_model->{pricing_model_type},
            amount => $pricing_model->{amount},
            currency => $pricing_model->{currency},
            billing_frequency => $pricing_model->{billing_frequency},
            installments_allowed => $pricing_model->{installments_allowed},
            installment_count => $pricing_model->{installment_count},
            pricing_configuration => $pricing_model->{pricing_configuration},

            # Resource Allocation
            resources => $resource_allocation->{resources},
            quotas => $resource_allocation->{quotas},

            # Requirements & Rules
            requirements => $requirements_rules->{requirements},
            rules => $requirements_rules->{rules},
        };

        # Format currency display
        if ($summary->{currency} eq 'USD') {
            $summary->{formatted_amount} = sprintf('$%.2f', $summary->{amount} || 0);
        }
        else {
            $summary->{formatted_amount} = sprintf('%.2f %s', $summary->{amount} || 0, $summary->{currency});
        }

        return {
            summary => $summary,
            can_activate => !$data->{completed},
            activation_options => [
                { value => 'now', label => 'Activate immediately' },
                { value => 'scheduled', label => 'Schedule activation' },
                { value => 'draft', label => 'Save as draft' },
            ]
        };
    }

    method get_user_id($db, $run) {
        my $data = $run->data || {};

        # Try to get from run data
        if ($data->{user_id}) {
            return $data->{user_id};
        }

        # Get from session if available
        # This would normally come from the controller/session
        # For now, return a system user ID
        return '00000000-0000-0000-0000-000000000001';
    }
}

1;