# ABOUTME: Workflow step for collecting basic pricing plan information
# ABOUTME: Handles plan name, type, target audience, and scope configuration

use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::PricingPlanBasics :isa(Registry::DAO::WorkflowStep) {
    use Carp qw( croak );
    use Registry::DAO::PricingPlan;

    method process ($db, $form_data, $run = undef) {
        $run //= do { my $w = $self->workflow($db); $w->latest_run($db) };

        # Validate required fields
        my @errors;
        push @errors, "Plan name is required" unless $form_data->{plan_name};
        push @errors, "Plan type is required" unless $form_data->{plan_type};
        push @errors, "Plan scope is required" unless $form_data->{plan_scope};

        if (@errors) {
            return {
                stay => 1,
                errors => \@errors
            };
        }

        # Authorship comes from the server-stamped run tenant, never the form.
        my $offering_tenant_id = $self->get_tenant_id($db, $run)
            or return { stay => 1, errors => ["This plan has no tenant to author it"] };

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
                plan_scope => $form_data->{plan_scope},
                offering_tenant_id => $offering_tenant_id,
            }
        });

        # Move to next step
        my $next_step = $self->next_step($db);
        return { next_step => $next_step ? $next_step->slug : undef };
    }

    # The run's tenant by slug, registry included; undef when there is none.
    method get_tenant_id($db, $run) {
        my $slug = ($run->data || {})->{__tenant_slug};
        return undef unless defined $slug && length $slug;
        require Registry::DAO::Tenant;
        my $tenant = Registry::DAO::Tenant->find($db, { slug => $slug });
        return $tenant ? $tenant->id : undef;
    }

    method prepare_template_data($db, $run, $params = {}) {
        # Prepare data for template
        return {
            plan_types => [
                { value => 'subscription', label => 'Subscription', description => 'Recurring monthly or yearly billing' },
                { value => 'per_use', label => 'Per-Use', description => 'Pay only for what you use' },
                { value => 'hybrid', label => 'Hybrid', description => 'Base fee plus usage charges' },
                { value => 'one_time', label => 'One-Time', description => 'Single payment for access' },
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