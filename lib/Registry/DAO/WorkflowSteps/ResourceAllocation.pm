# ABOUTME: Workflow step for defining resource allocations and quotas
# ABOUTME: Configures what resources and features are included in the pricing plan

use 5.40.2;
use utf8;
use experimental qw(try signatures);
use Object::Pad;

class Registry::DAO::WorkflowSteps::ResourceAllocation :isa(Registry::DAO::WorkflowStep) {
    use Carp qw( croak );
    use Mojo::JSON qw( encode_json );

    method process ($db, $form_data) {
        my $workflow = $self->workflow($db);
        my $run = $workflow->latest_run($db);

        # Build resources configuration
        my $resources = {};
        my $quotas = {};
        my $features = [];

        # Service quotas
        if (defined $form_data->{classes_per_month}) {
            $resources->{classes_per_month} = int($form_data->{classes_per_month});
        }
        if (defined $form_data->{sessions_per_program}) {
            $resources->{sessions_per_program} = int($form_data->{sessions_per_program});
        }
        if (defined $form_data->{api_calls_per_day}) {
            $resources->{api_calls_per_day} = int($form_data->{api_calls_per_day});
        }
        if (defined $form_data->{storage_gb}) {
            $resources->{storage_gb} = int($form_data->{storage_gb});
        }
        if (defined $form_data->{bandwidth_gb}) {
            $resources->{bandwidth_gb} = int($form_data->{bandwidth_gb});
        }

        # User limits
        if (defined $form_data->{max_students}) {
            $resources->{max_students} = int($form_data->{max_students});
        }
        if (defined $form_data->{staff_accounts}) {
            $resources->{staff_accounts} = int($form_data->{staff_accounts});
        }
        if (defined $form_data->{family_members}) {
            $resources->{family_members} = int($form_data->{family_members});
        }
        if (defined $form_data->{admin_accounts}) {
            $resources->{admin_accounts} = int($form_data->{admin_accounts});
        }

        # Feature gates
        my @all_features = qw(
            attendance_tracking
            payment_processing
            email_notifications
            sms_notifications
            custom_reports
            api_access
            white_label
            priority_support
            custom_integrations
            advanced_analytics
            waitlist_management
            installment_payments
            discount_codes
            parent_portal
            staff_portal
        );

        for my $feature (@all_features) {
            if ($form_data->{"feature_$feature"}) {
                push @$features, $feature;
            }
        }
        $resources->{features} = $features if @$features;

        # Geographic scope
        if ($form_data->{geographic_scope}) {
            my @scopes = ref $form_data->{geographic_scope} eq 'ARRAY'
                ? @{$form_data->{geographic_scope}}
                : split(/,/, $form_data->{geographic_scope});
            $resources->{geographic_scope} = \@scopes;
        }

        # Usage restrictions
        if ($form_data->{peak_hours_access}) {
            $resources->{peak_hours_access} = $form_data->{peak_hours_access} eq 'yes' ? 1 : 0;
        }
        if ($form_data->{concurrent_users}) {
            $resources->{concurrent_users} = int($form_data->{concurrent_users});
        }

        # Quota policies
        $quotas->{reset_period} = $form_data->{reset_period} || 'monthly';
        $quotas->{rollover_allowed} = $form_data->{rollover_allowed} eq 'yes' ? 1 : 0;
        $quotas->{overage_policy} = $form_data->{overage_policy} || 'block';

        if ($quotas->{overage_policy} eq 'charge') {
            $quotas->{overage_rate} = $form_data->{overage_rate} || 0;
        }

        # Validate at least some resources are defined
        if (!keys %$resources) {
            return {
                stay => 1,
                errors => ["At least one resource allocation must be defined"]
            };
        }

        # Store resource allocation in run data
        my $existing_data = $run->data || {};
        $run->update_data($db, {
            %$existing_data,
            resource_allocation => {
                resources => $resources,
                quotas => $quotas,
            }
        });

        # Move to next step
        my $next_step = $self->next_step($db);
        return { next_step => $next_step ? $next_step->slug : undef };
    }

    method prepare_template_data($db, $run) {
        my $existing_data = $run->data || {};
        my $plan_basics = $existing_data->{plan_basics} || {};
        my $pricing_model = $existing_data->{pricing_model} || {};

        return {
            plan_name => $plan_basics->{plan_name},
            plan_type => $plan_basics->{plan_type},
            pricing_type => $pricing_model->{pricing_model_type},

            features => [
                { name => 'attendance_tracking', label => 'Attendance Tracking', category => 'core' },
                { name => 'payment_processing', label => 'Payment Processing', category => 'core' },
                { name => 'email_notifications', label => 'Email Notifications', category => 'communication' },
                { name => 'sms_notifications', label => 'SMS Notifications', category => 'communication' },
                { name => 'custom_reports', label => 'Custom Reports', category => 'analytics' },
                { name => 'api_access', label => 'API Access', category => 'integration' },
                { name => 'white_label', label => 'White Label Branding', category => 'premium' },
                { name => 'priority_support', label => 'Priority Support', category => 'support' },
                { name => 'custom_integrations', label => 'Custom Integrations', category => 'integration' },
                { name => 'advanced_analytics', label => 'Advanced Analytics', category => 'analytics' },
                { name => 'waitlist_management', label => 'Waitlist Management', category => 'core' },
                { name => 'installment_payments', label => 'Installment Payments', category => 'payments' },
                { name => 'discount_codes', label => 'Discount Codes', category => 'payments' },
                { name => 'parent_portal', label => 'Parent Portal', category => 'portals' },
                { name => 'staff_portal', label => 'Staff Portal', category => 'portals' },
            ],

            reset_periods => [
                { value => 'daily', label => 'Daily' },
                { value => 'weekly', label => 'Weekly' },
                { value => 'monthly', label => 'Monthly' },
                { value => 'quarterly', label => 'Quarterly' },
                { value => 'yearly', label => 'Yearly' },
            ],

            overage_policies => [
                { value => 'block', label => 'Block when limit reached' },
                { value => 'notify', label => 'Notify but allow' },
                { value => 'charge', label => 'Charge for overages' },
                { value => 'throttle', label => 'Throttle/slow down service' },
            ],

            geographic_regions => [
                { value => 'US', label => 'United States' },
                { value => 'CA', label => 'Canada' },
                { value => 'EU', label => 'European Union' },
                { value => 'UK', label => 'United Kingdom' },
                { value => 'APAC', label => 'Asia-Pacific' },
                { value => 'LATAM', label => 'Latin America' },
                { value => 'GLOBAL', label => 'Global' },
            ]
        };
    }
}

1;