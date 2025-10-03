# ABOUTME: Workflow step for defining eligibility requirements and business rules
# ABOUTME: Configures discounts, eligibility criteria, and renewal policies

use 5.40.2;
use utf8;
use experimental qw(try signatures);
use Object::Pad;

class Registry::DAO::WorkflowSteps::RequirementsRules :isa(Registry::DAO::WorkflowStep) {
    use Carp qw( croak );
    use DateTime;

    method process ($db, $form_data) {
        my $workflow = $self->workflow($db);
        my $run = $workflow->latest_run($db);

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

        # Early bird discount
        if ($form_data->{early_bird_enabled}) {
            $requirements->{early_bird_enabled} = 1;
            $requirements->{early_bird_discount} = $form_data->{early_bird_discount} || 0;
            $requirements->{early_bird_cutoff_date} = $form_data->{early_bird_cutoff_date};

            # Validate cutoff date
            if ($requirements->{early_bird_cutoff_date}) {
                try {
                    my $dt = DateTime->new(
                        year => substr($requirements->{early_bird_cutoff_date}, 0, 4),
                        month => substr($requirements->{early_bird_cutoff_date}, 5, 2),
                        day => substr($requirements->{early_bird_cutoff_date}, 8, 2),
                    );
                    # Date is valid
                }
                catch ($e) {
                    return {
                        stay => 1,
                        errors => ["Invalid early bird cutoff date format"]
                    };
                }
            }
        }

        # Family/group discounts
        if ($form_data->{family_discount_enabled}) {
            $requirements->{family_discount_enabled} = 1;
            $requirements->{min_children} = int($form_data->{min_children} || 2);
            $requirements->{family_discount_type} = $form_data->{family_discount_type} || 'percentage';
            $requirements->{family_discount_amount} = $form_data->{family_discount_amount} || 0;
        }

        # Volume discounts
        if ($form_data->{volume_discount_enabled}) {
            $requirements->{volume_discount_enabled} = 1;
            $requirements->{volume_tiers} = [];

            # Process volume tiers
            if ($form_data->{volume_tiers}) {
                for my $tier (@{$form_data->{volume_tiers}}) {
                    push @{$requirements->{volume_tiers}}, {
                        min_quantity => $tier->{min_quantity},
                        max_quantity => $tier->{max_quantity},
                        discount => $tier->{discount}
                    };
                }
            }
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

    method prepare_template_data($db, $run) {
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

            discount_types => [
                { value => 'percentage', label => 'Percentage off' },
                { value => 'fixed', label => 'Fixed amount off' },
            ]
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