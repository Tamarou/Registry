use 5.34.0;
use experimental 'signatures';
use Object::Pad;

class Registry::DAO::WorkflowSteps::TenantPayment :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Subscription;
    use Registry::Utility::ErrorHandler;
    use JSON qw(encode_json decode_json);
    use Carp qw(croak);

    method process($db, $form_data) {
        my $workflow = $self->workflow($db);
        my $run = $workflow->latest_run($db);
        my $error_handler = Registry::Utility::ErrorHandler->new();
        
        # Check for rate limiting
        if (my $rate_limit_error = $self->check_rate_limits($db, $run)) {
            $error_handler->log_error($rate_limit_error, { 
                workflow_id => $workflow->id, 
                run_id => $run->id,
                form_data => $form_data 
            });
            return {
                next_step => $self->id,
                errors => [$rate_limit_error->{user_message}],
                data => $self->prepare_payment_data($db, $run)
            };
        }
        
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
        my $error_handler = Registry::Utility::ErrorHandler->new();
        
        # Get tenant and profile data from workflow
        my $tenant_data = $run->data->{tenant} || {};
        my $profile_data = $run->data->{profile} || {};
        
        # Validate required data
        unless ($profile_data->{billing_email} && $profile_data->{organization_name}) {
            my $validation_error = $error_handler->handle_validation_error(
                'billing_info', 
                'Missing required billing information. Please complete the profile step first.'
            );
            return {
                next_step => $self->id,
                errors => [$validation_error->{user_message}],
                data => $self->prepare_payment_data($db, $run)
            };
        }

        # Check retry count and apply exponential backoff if needed
        my $retry_count = $self->get_retry_count($run);
        if ($retry_count >= $self->max_retries) {
            return {
                next_step => $self->id,
                errors => ['Maximum payment attempts exceeded. Please contact support for assistance.'],
                data => $self->prepare_payment_data($db, $run),
                retry_exceeded => 1
            };
        }

        # Create Stripe customer with enhanced error handling
        my $customer;
        eval {
            $customer = $subscription_dao->create_customer({
                name => $profile_data->{organization_name},
                id => $tenant_data->{id} // 'temp_' . time()
            }, $profile_data);
        };
        
        if ($@ || !$customer) {
            $self->increment_retry_count($db, $run);
            my $error_details = $error_handler->handle_system_error('stripe_customer', $@, {
                organization_name => $profile_data->{organization_name},
                retry_count => $retry_count + 1
            });
            
            $error_handler->log_error($error_details, {
                workflow_id => $run->workflow_id,
                run_id => $run->id,
                step => 'create_customer'
            });
            
            return {
                next_step => $self->id,
                errors => [$error_details->{user_message}],
                data => $self->prepare_payment_data($db, $run),
                retry_count => $retry_count + 1,
                retry_delay => $error_details->{retry_delay}
            };
        }

        # Create setup intent for payment method collection with enhanced error handling
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
            $self->increment_retry_count($db, $run);
            my $error_details = $error_handler->handle_payment_error($@, {
                step => 'create_setup_intent',
                customer_id => $customer->{id},
                retry_count => $retry_count + 1
            });
            
            $error_handler->log_error($error_details, {
                workflow_id => $run->workflow_id,
                run_id => $run->id,
                step => 'create_setup_intent'
            });
            
            return {
                next_step => $self->id,
                errors => [$error_details->{user_message}],
                data => $self->prepare_payment_data($db, $run),
                retry_count => $retry_count + 1,
                should_retry => $error_details->{should_retry}
            };
        }

        # Store setup intent data in workflow
        $run->update_data($db, {
            payment_setup => {
                stripe_customer_id => $customer->{id},
                setup_intent_id => $setup_intent->{id},
                client_secret => $setup_intent->{client_secret},
                created_at => time()
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

    # Rate limiting to prevent abuse
    method check_rate_limits($db, $run) {
        my $window_minutes = 15;
        my $max_attempts = 5;
        my $current_time = time();
        
        # Get recent attempts from workflow data
        my $recent_attempts = $run->data->{payment_attempts} || [];
        
        # Filter to only attempts within the time window
        my @recent = grep { 
            ($current_time - $_->{timestamp}) < ($window_minutes * 60) 
        } @$recent_attempts;
        
        if (@recent >= $max_attempts) {
            my $error_handler = Registry::Utility::ErrorHandler->new();
            return $error_handler->handle_system_error('rate_limit', 
                "Too many payment attempts. Please wait $window_minutes minutes before trying again.", {
                    attempts_count => scalar(@recent),
                    window_minutes => $window_minutes,
                    next_allowed_at => $recent[0]->{timestamp} + ($window_minutes * 60)
                });
        }
        
        # Record this attempt
        push @recent, { timestamp => $current_time, action => 'payment_attempt' };
        $run->update_data($db, { payment_attempts => \@recent });
        
        return undef;  # No rate limit hit
    }

    # Session timeout and recovery
    method check_session_validity($db, $run) {
        my $session_timeout_hours = 24;  # 24 hour session timeout
        my $payment_setup = $run->data->{payment_setup} || {};
        
        if (my $created_at = $payment_setup->{created_at}) {
            my $elapsed_hours = (time() - $created_at) / 3600;
            
            if ($elapsed_hours > $session_timeout_hours) {
                # Session expired, clear payment setup data
                $run->update_data($db, { payment_setup => undef });
                
                my $error_handler = Registry::Utility::ErrorHandler->new();
                return $error_handler->handle_workflow_interruption(
                    $run->workflow_id, 
                    $self->id, 
                    'session_timeout',
                    { 
                        elapsed_hours => $elapsed_hours,
                        timeout_hours => $session_timeout_hours,
                        can_restart => 1
                    }
                );
            }
        }
        
        return undef;  # Session is valid
    }

    # Validate Stripe service availability
    method check_stripe_service($db) {
        my $subscription_dao = Registry::DAO::Subscription->new(db => $db);
        
        eval {
            # Simple API call to check if Stripe is available
            $subscription_dao->check_api_health();
        };
        
        if ($@) {
            my $error_handler = Registry::Utility::ErrorHandler->new();
            return $error_handler->handle_system_error('stripe_api', $@, {
                service => 'stripe',
                check_type => 'api_health'
            });
        }
        
        return undef;  # Service is available
    }
}