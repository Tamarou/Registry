# ABOUTME: Workflow step for defining eligibility requirements and business rules
# ABOUTME: Configures eligibility criteria, trial terms, and renewal policies

use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::RequirementsRules :isa(Registry::DAO::WorkflowStep) {
    use Carp qw( croak );

    method process ($db, $form_data, $run = undef) {
        $run //= do { my $w = $self->workflow($db); $w->latest_run($db) };

        my $requirements = {};
        my $rules = {};

        # Eligibility requirements
        if ($form_data->{min_age}) {
            $requirements->{min_age} = int($form_data->{min_age});
        }
        if ($form_data->{max_age}) {
            $requirements->{max_age} = int($form_data->{max_age});
        }
        if ($form_data->{location_restrictions}) {
            my @locations = ref $form_data->{location_restrictions} eq 'ARRAY'
                ? @{$form_data->{location_restrictions}}
                : split(/,/, $form_data->{location_restrictions});
            $requirements->{location_restrictions} = \@locations;
        }
        if ($form_data->{required_memberships}) {
            my @memberships = ref $form_data->{required_memberships} eq 'ARRAY'
                ? @{$form_data->{required_memberships}}
                : split(/,/, $form_data->{required_memberships});
            $requirements->{required_memberships} = \@memberships;
        }
        if ($form_data->{prerequisite_programs}) {
            my @prereqs = ref $form_data->{prerequisite_programs} eq 'ARRAY'
                ? @{$form_data->{prerequisite_programs}}
                : split(/,/, $form_data->{prerequisite_programs});
            $requirements->{prerequisite_programs} = \@prereqs;
        }

        # Seasonal availability
        if ($form_data->{seasonal_availability}) {
            $rules->{seasonal_availability} = 1;
            $rules->{available_from} = $form_data->{available_from};
            $rules->{available_to} = $form_data->{available_to};
        }

        # Renewal policies
        $rules->{auto_renew} = $form_data->{auto_renew} eq 'yes' ? 1 : 0;
        $rules->{renewal_notice_days} = int($form_data->{renewal_notice_days} || 30);
        $rules->{cancellation_notice_days} = int($form_data->{cancellation_notice_days} || 7);
        $rules->{refund_policy} = $form_data->{refund_policy} || 'no_refund';

        # Trial period
        if ($form_data->{trial_enabled}) {
            $rules->{trial_enabled} = 1;
            $rules->{trial_days} = int($form_data->{trial_days} || 7);
            $rules->{trial_features} = $form_data->{trial_features} || 'full';
        }

        # Proration rules
        $rules->{prorate_on_upgrade} = $form_data->{prorate_on_upgrade} eq 'yes' ? 1 : 0;
        $rules->{prorate_on_downgrade} = $form_data->{prorate_on_downgrade} eq 'yes' ? 1 : 0;

        # Store requirements and rules in run data
        my $existing_data = $run->data || {};
        $run->update_data($db, {
            %$existing_data,
            requirements_rules => {
                requirements => $requirements,
                rules => $rules,
            }
        });

        # Move to next step
        my $next_step = $self->next_step($db);
        return { next_step => $next_step ? $next_step->slug : undef };
    }

    method prepare_template_data($db, $run, $params = {}) {
        my $existing_data = $run->data || {};
        my $plan_basics = $existing_data->{plan_basics} || {};

        # Get available programs for prerequisites
        my $tenant_id = $self->get_tenant_id($db, $run);
        require Registry::DAO::Program;
        my @programs = Registry::DAO::Program->find($db, { tenant_id => $tenant_id });

        return {
            plan_name => $plan_basics->{plan_name},
            plan_type => $plan_basics->{plan_type},
            target_audience => $plan_basics->{target_audience},

            programs => \@programs,

            refund_policies => [
                { value => 'no_refund', label => 'No refunds' },
                { value => 'prorated', label => 'Prorated refund' },
                { value => 'full_within_days', label => 'Full refund within X days' },
                { value => 'credit_only', label => 'Credit only' },
                { value => 'case_by_case', label => 'Case by case basis' },
            ],

            trial_feature_levels => [
                { value => 'full', label => 'Full features' },
                { value => 'limited', label => 'Limited features' },
                { value => 'basic', label => 'Basic features only' },
            ],
        };
    }

    method get_tenant_id($db, $run) {
        my $data = $run->data || {};

        if ($data->{plan_basics} && $data->{plan_basics}{offering_tenant_id}) {
            return $data->{plan_basics}{offering_tenant_id};
        }

        # Check if we have tenant context
        if ($data->{__tenant_slug} && $data->{__tenant_slug} ne 'registry') {
            require Registry::DAO::Tenant;
            my $tenant = Registry::DAO::Tenant->find($db, { slug => $data->{__tenant_slug} });
            return $tenant->id if $tenant;
        }

        # Default to platform tenant
        return '00000000-0000-0000-0000-000000000000';
    }
}

1;