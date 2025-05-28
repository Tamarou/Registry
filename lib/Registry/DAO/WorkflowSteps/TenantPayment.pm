use 5.34.0;
use experimental 'signatures';
use Object::Pad;

class Registry::DAO::WorkflowSteps::TenantPayment :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Subscription;
    use JSON qw(encode_json decode_json);
    use Carp qw(croak);

    method process($db, $form_data) {
        my $workflow = $self->workflow($db);
        my $run = $workflow->latest_run($db);
        
        # Handle setup intent completion
        if ($form_data->{setup_intent_id}) {
            return $self->handle_setup_completion($db, $run, $form_data);
        }
        
        # Handle payment method collection
        if ($form_data->{collect_payment_method}) {
            return $self->create_setup_intent($db, $run, $form_data);
        }
        
        # Initial payment page load
        return {
            next_step => $self->id,
            data => $self->prepare_payment_data($db, $run)
        };
    }

    method prepare_payment_data($db, $run) {
        # Get tenant subscription pricing configuration
        my $subscription_config = $self->get_subscription_config($db);
        
        # Get organization info from workflow data
        my $org_data = $run->data->{profile} || {};
        my $billing_summary = {
            organization_name => $org_data->{organization_name} || 'Your Organization',
            subdomain => $org_data->{subdomain} || 'your-org',
            billing_email => $org_data->{billing_email},
            plan_details => $subscription_config
        };

        return {
            billing_summary => $billing_summary,
            stripe_publishable_key => $ENV{STRIPE_PUBLISHABLE_KEY},
            subscription_config => $subscription_config,
            show_payment_form => 0,
        };
    }

    method get_subscription_config($db) {
        # This could be stored in database configuration table, but for now use defaults
        # In production, this would be configurable via admin interface
        return {
            plan_name => 'Registry Professional',
            monthly_amount => 20000, # $200.00 in cents
            currency => 'usd',
            trial_days => 30,
            description => 'Complete after-school program management solution',
            features => [
                'Unlimited student enrollments',
                'Attendance tracking and reporting', 
                'Parent communication tools',
                'Payment processing',
                'Waitlist management',
                'Staff scheduling',
                'Custom reporting'
            ],
            billing_cycle => 'monthly',
            formatted_price => '$200.00/month'
        };
    }

    method create_setup_intent($db, $run, $form_data) {
        my $subscription_dao = Registry::DAO::Subscription->new(db => $db);
        
        # Get tenant and profile data from workflow
        my $tenant_data = $run->data->{tenant} || {};
        my $profile_data = $run->data->{profile} || {};
        
        # Validate required data
        unless ($profile_data->{billing_email} && $profile_data->{organization_name}) {
            return {
                next_step => $self->id,
                errors => ['Missing required billing information. Please complete the profile step first.'],
                data => $self->prepare_payment_data($db, $run)
            };
        }

        # Create Stripe customer
        my $customer;
        eval {
            $customer = $subscription_dao->create_customer({
                name => $profile_data->{organization_name},
                id => $tenant_data->{id} // 'temp_' . time()
            }, $profile_data);
        };
        
        if ($@ || !$customer) {
            return {
                next_step => $self->id,
                errors => ['Failed to set up billing. Please try again or contact support.'],
                data => $self->prepare_payment_data($db, $run)
            };
        }

        # Create setup intent for payment method collection
        my $setup_intent;
        eval {
            $setup_intent = $subscription_dao->create_setup_intent($customer->{id}, {
                usage => 'off_session',
                metadata => {
                    tenant_workflow => $run->id,
                    organization_name => $profile_data->{organization_name}
                }
            });
        };

        if ($@ || !$setup_intent) {
            return {
                next_step => $self->id,
                errors => ['Failed to initialize payment setup. Please try again.'],
                data => $self->prepare_payment_data($db, $run)
            };
        }

        # Store setup intent data in workflow
        $run->update_data($db, {
            payment_setup => {
                stripe_customer_id => $customer->{id},
                setup_intent_id => $setup_intent->{id},
                client_secret => $setup_intent->{client_secret}
            }
        });

        return {
            next_step => $self->id,
            data => {
                %{$self->prepare_payment_data($db, $run)},
                show_payment_form => 1,
                client_secret => $setup_intent->{client_secret},
                setup_intent_id => $setup_intent->{id}
            }
        };
    }

    method handle_setup_completion($db, $run, $form_data) {
        my $subscription_dao = Registry::DAO::Subscription->new(db => $db);
        my $setup_data = $run->data->{payment_setup} || {};
        
        unless ($setup_data->{setup_intent_id} eq $form_data->{setup_intent_id}) {
            return {
                next_step => $self->id,
                errors => ['Invalid payment setup. Please try again.'],
                data => $self->prepare_payment_data($db, $run)
            };
        }

        # Retrieve and verify setup intent
        my $setup_intent;
        eval {
            $setup_intent = $subscription_dao->get_setup_intent($form_data->{setup_intent_id});
        };

        if ($@ || !$setup_intent || $setup_intent->{status} ne 'succeeded') {
            my $error_msg = 'Payment method setup failed.';
            if ($setup_intent && $setup_intent->{last_setup_error}) {
                $error_msg .= ' ' . $setup_intent->{last_setup_error}->{message};
            }
            
            return {
                next_step => $self->id,
                errors => [$error_msg],
                data => $self->prepare_payment_data($db, $run)
            };
        }

        # Create subscription with trial
        my $subscription;
        eval {
            my $config = $self->get_subscription_config($db);
            $subscription = $subscription_dao->create_subscription_with_config(
                $setup_data->{stripe_customer_id},
                $setup_intent->{payment_method},
                $config
            );
        };

        if ($@ || !$subscription) {
            return {
                next_step => $self->id,
                errors => ['Failed to create subscription. Please contact support.'],
                data => $self->prepare_payment_data($db, $run)
            };
        }

        # Store subscription info in workflow data
        $run->update_data($db, {
            subscription => {
                stripe_subscription_id => $subscription->{id},
                trial_ends_at => $subscription->{trial_end},
                status => $subscription->{status}
            }
        });

        # Payment successful, move to completion
        return { next_step => 'complete' };
    }

    method template { 'tenant-signup/payment' }

    # Retry logic for failed attempts
    method get_retry_count($run) {
        return ($run->data->{payment_retry_count} || 0);
    }

    method increment_retry_count($db, $run) {
        my $new_count = $self->get_retry_count($run) + 1;
        $run->update_data($db, { payment_retry_count => $new_count });
        return $new_count;
    }

    method max_retries { 3 }
}