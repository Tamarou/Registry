# ABOUTME: Workflow step for configuring the pricing model and payment structure
# ABOUTME: Handles pricing type, amounts, billing frequency, and installment options

use 5.40.2;
use utf8;
use experimental qw(try signatures);
use Object::Pad;

class Registry::DAO::WorkflowSteps::PricingModel :isa(Registry::DAO::WorkflowStep) {
    use Carp qw( croak );

    method process ($db, $form_data) {
        my $workflow = $self->workflow($db);
        my $run = $workflow->latest_run($db);

        # Validate required fields
        my @errors;
        push @errors, "Pricing type is required" unless $form_data->{pricing_model_type};
        push @errors, "Currency is required" unless $form_data->{currency};

        # Validate based on pricing type
        my $pricing_type = $form_data->{pricing_model_type} || '';

        if ($pricing_type eq 'fixed') {
            push @errors, "Base amount is required for fixed pricing"
                unless defined $form_data->{base_amount} && $form_data->{base_amount} > 0;
        }
        elsif ($pricing_type eq 'percentage') {
            push @errors, "Percentage rate is required"
                unless defined $form_data->{percentage_rate} && $form_data->{percentage_rate} > 0;
            push @errors, "Percentage base must be selected"
                unless $form_data->{percentage_base};
        }
        elsif ($pricing_type eq 'tiered') {
            push @errors, "At least one pricing tier must be defined"
                unless $form_data->{tiers} && @{$form_data->{tiers}};
        }
        elsif ($pricing_type eq 'usage_based') {
            push @errors, "Usage metric must be defined"
                unless $form_data->{usage_metric};
            push @errors, "Rate per unit is required"
                unless defined $form_data->{rate_per_unit} && $form_data->{rate_per_unit} > 0;
        }
        elsif ($pricing_type eq 'hybrid') {
            push @errors, "Base amount is required for hybrid pricing"
                unless defined $form_data->{base_amount} && $form_data->{base_amount} >= 0;
            push @errors, "Variable component must be configured"
                unless $form_data->{variable_component};
        }
        elsif ($pricing_type eq 'transaction_fee') {
            push @errors, "Transaction fee configuration is required"
                unless defined $form_data->{per_transaction} || defined $form_data->{transaction_percentage};
        }

        if (@errors) {
            return {
                stay => 1,
                errors => \@errors
            };
        }

        # Build pricing configuration
        my $pricing_config = $self->build_pricing_configuration($form_data);

        # Store pricing model in run data
        my $existing_data = $run->data || {};
        $run->update_data($db, {
            %$existing_data,
            pricing_model => {
                pricing_model_type => $pricing_type,
                amount => $form_data->{base_amount} || 0,
                currency => $form_data->{currency},
                billing_frequency => $form_data->{billing_frequency} || 'monthly',
                installments_allowed => $form_data->{installments_allowed} ? 1 : 0,
                installment_count => $form_data->{installment_count},
                pricing_configuration => $pricing_config,
            }
        });

        # Move to next step
        my $next_step = $self->next_step($db);
        return { next_step => $next_step ? $next_step->slug : undef };
    }

    method build_pricing_configuration($form_data) {
        my $config = {};
        my $type = $form_data->{pricing_model_type};

        if ($type eq 'fixed') {
            $config = {
                base_amount => $form_data->{base_amount},
                billing_frequency => $form_data->{billing_frequency},
            };
        }
        elsif ($type eq 'percentage') {
            $config = {
                percentage => $form_data->{percentage_rate} / 100,
                applies_to => $form_data->{percentage_base},
                minimum_amount => $form_data->{minimum_amount} || 0,
                maximum_amount => $form_data->{maximum_amount} || undef,
            };
        }
        elsif ($type eq 'tiered') {
            $config = {
                tiers => $form_data->{tiers},
                tier_mode => $form_data->{tier_mode} || 'graduated', # graduated or volume
            };
        }
        elsif ($type eq 'usage_based') {
            $config = {
                usage_metric => $form_data->{usage_metric},
                rate_per_unit => $form_data->{rate_per_unit},
                included_units => $form_data->{included_units} || 0,
                overage_rate => $form_data->{overage_rate} || $form_data->{rate_per_unit},
            };
        }
        elsif ($type eq 'hybrid') {
            $config = {
                monthly_base => $form_data->{base_amount},
                variable_component => $form_data->{variable_component},
                percentage => ($form_data->{variable_percentage} || 0) / 100,
                applies_to => $form_data->{variable_base} || 'customer_payments',
            };
        }
        elsif ($type eq 'transaction_fee') {
            $config = {
                per_transaction => $form_data->{per_transaction} || 0,
                percentage => ($form_data->{transaction_percentage} || 0) / 100,
                minimum_fee => $form_data->{minimum_fee} || 0,
                maximum_fee => $form_data->{maximum_fee} || undef,
            };
        }

        return $config;
    }

    method prepare_template_data($db, $run) {
        my $existing_data = $run->data || {};
        my $plan_basics = $existing_data->{plan_basics} || {};

        return {
            plan_name => $plan_basics->{plan_name},
            plan_type => $plan_basics->{plan_type},
            pricing_model_types => [
                { value => 'fixed', label => 'Fixed Price', description => 'Flat rate billing' },
                { value => 'percentage', label => 'Percentage', description => 'Percentage of revenue or transactions' },
                { value => 'tiered', label => 'Tiered', description => 'Different rates at different volumes' },
                { value => 'usage_based', label => 'Usage-Based', description => 'Pay per unit consumed' },
                { value => 'hybrid', label => 'Hybrid', description => 'Base fee plus variable charges' },
                { value => 'transaction_fee', label => 'Transaction Fee', description => 'Per-transaction charges' },
            ],
            currencies => [
                { value => 'USD', label => 'US Dollar' },
                { value => 'EUR', label => 'Euro' },
                { value => 'GBP', label => 'British Pound' },
                { value => 'CAD', label => 'Canadian Dollar' },
            ],
            billing_frequencies => [
                { value => 'monthly', label => 'Monthly' },
                { value => 'yearly', label => 'Yearly' },
                { value => 'quarterly', label => 'Quarterly' },
                { value => 'per_use', label => 'Per Use' },
            ],
            percentage_bases => [
                { value => 'customer_payments', label => 'Customer Payments' },
                { value => 'program_revenue', label => 'Program Revenue' },
                { value => 'transaction_volume', label => 'Transaction Volume' },
                { value => 'gross_revenue', label => 'Gross Revenue' },
            ]
        };
    }
}

1;