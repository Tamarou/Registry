# ABOUTME: Workflow step for tenant pricing plan selection during signup
# ABOUTME: Fetches active platform pricing plans and handles plan selection

use 5.34.0;
use experimental 'signatures';
use Object::Pad;

class Registry::DAO::WorkflowSteps::PricingPlanSelection :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::PricingPlan;
    use Registry::DAO::PricingRelationship;
    use Carp qw(croak);

    method process($db, $form_data) {
        my $workflow = $self->workflow($db);
        my $run = $workflow->latest_run($db);

        # Check if plan selection was submitted
        unless (exists $form_data->{selected_plan_id}) {
            # Show plan selection page (unless we're in auto-select mode for workflow testing)
            my $pricing_data = $self->prepare_pricing_data($db);
            my $pricing_plans = $pricing_data->{pricing_plans} || [];

            # Auto-select only when explicitly requested AND we have plans available
            if (exists $form_data->{__auto_select_plan} && @$pricing_plans) {
                # Auto-select the first plan for testing purposes
                $form_data->{selected_plan_id} = $pricing_plans->[0]->{id};
                # Continue processing with auto-selected plan
            } else {
                # Show plan selection page
                return {
                    next_step => $self->id,
                    data => $pricing_data
                };
            }
        }

        # Validate and process plan selection
        my $selected_plan_id = $form_data->{selected_plan_id};

        # Check for empty or invalid plan ID
        if (!$selected_plan_id || $selected_plan_id eq '') {
            return {
                next_step => $self->id,
                errors => ['Please select a pricing plan.'],
                data => $self->prepare_pricing_data($db)
            };
        }

        # Validate plan exists and is available
        my $selected_plan = $self->validate_plan_selection($db, $selected_plan_id);

        if (!$selected_plan) {
            return {
                next_step => $self->id,
                errors => ['The selected pricing plan is not available.'],
                data => $self->prepare_pricing_data($db)
            };
        }

        # Store selected plan in workflow data
        $run->update_data($db, {
            selected_pricing_plan => {
                id => $selected_plan->id,
                plan_name => $selected_plan->plan_name,
                amount => int($selected_plan->amount),  # Convert to integer
                currency => $selected_plan->currency,
                pricing_configuration => $selected_plan->pricing_configuration
            }
        });

        # Move to next step (typically payment)
        return {};
    }

    method prepare_pricing_data($db) {
        my $platform_uuid = '00000000-0000-0000-0000-000000000000';

        # Get active pricing plans available for new tenant signups
        my @relationships = Registry::DAO::PricingRelationship->find($db, {
            provider_id => $platform_uuid,
            status => 'active'
        });

        my @pricing_plans;
        for my $relationship (@relationships) {
            my $plan = $relationship->get_pricing_plan($db);
            next unless $plan;
            next unless $plan->plan_scope eq 'tenant';  # Only tenant-scoped plans

            # Format plan data for template
            push @pricing_plans, {
                id => $plan->id,
                plan_name => $plan->plan_name,
                plan_type => $plan->plan_type,
                amount => int($plan->amount),  # Convert to integer
                currency => $plan->currency,
                pricing_configuration => $plan->pricing_configuration,
                metadata => $plan->metadata,
                formatted_price => $self->format_price($plan->amount, $plan->currency),
            };
        }

        # Sort plans by display order (if available) or by amount
        @pricing_plans = sort {
            my $order_a = $a->{metadata}->{display_order} // 999;
            my $order_b = $b->{metadata}->{display_order} // 999;
            $order_a <=> $order_b || $a->{amount} <=> $b->{amount}
        } @pricing_plans;

        return {
            pricing_plans => \@pricing_plans,
            organization_info => $self->get_organization_preview($db)
        };
    }

    method validate_plan_selection($db, $plan_id) {
        return unless $plan_id;

        # Check if plan_id looks like a valid UUID
        return unless $plan_id =~ /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

        # Find the plan - wrap in eval to handle database errors gracefully
        my $plan;
        eval {
            $plan = Registry::DAO::PricingPlan->find_by_id($db, $plan_id);
        };
        return unless $plan;

        # Verify plan is available for platform tenant signups
        my $platform_uuid = '00000000-0000-0000-0000-000000000000';

        my @relationships;
        eval {
            @relationships = Registry::DAO::PricingRelationship->find($db, {
                provider_id => $platform_uuid,
                pricing_plan_id => $plan_id,
                status => 'active'
            });
        };

        return unless @relationships;
        return unless $plan->plan_scope eq 'tenant';

        return $plan;
    }

    method get_organization_preview($db) {
        my $workflow = $self->workflow($db);
        my $run = $workflow->latest_run($db);
        my $data = $run->data || {};

        return {
            organization_name => $data->{name} || $data->{organization_name} || 'Your Organization',
            admin_email => $data->{admin_email} || $data->{billing_email} || '',
            subdomain => $data->{subdomain} || ''
        };
    }

    method format_price($amount_cents, $currency) {
        my $amount_dollars = $amount_cents / 100;

        if ($currency eq 'USD') {
            return sprintf('$%.0f', $amount_dollars);
        }

        return sprintf('%.0f %s', $amount_dollars, $currency);
    }

    method template { 'tenant-signup/pricing' }
}