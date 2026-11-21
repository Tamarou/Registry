# ABOUTME: Workflow step that handles payment/subscription setup for new tenants.
# ABOUTME: Provisions the tenant via Tenant->provision at payment-completion time.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::TenantPayment :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Subscription;
    use Registry::DAO::User;
    use Registry::DAO::Tenant;
    use Registry::DAO::MagicLinkToken;
    use Registry::DAO::Workflow;
    use Registry::DAO;
    use Registry::Utility::ErrorHandler;
    use JSON qw(encode_json decode_json);
    use Carp qw(croak);
    use DateTime;
    use Registry::Utility::PriceFormat qw(format_price);
    use Registry::PriceOps::RevenueShare ();

    method process($db, $form_data, $run = undef) {
        $run //= do { my $w = $self->workflow($db); $w->latest_run($db) };
        my $error_handler = Registry::Utility::ErrorHandler->new();

        # Check for rate limiting
        if (my $rate_limit_error = $self->check_rate_limits($db, $run)) {
            $error_handler->log_error($rate_limit_error, {
                workflow_id => $self->workflow($db)->id,
                run_id => $run->id,
                form_data => $form_data 
            });
            return {
                next_step => $self->id,
                errors => [$rate_limit_error->{user_message}],
                data => $self->prepare_payment_data($db, $run)
            };
        }
        
        # Handle payment method collection with setup intent (testing scenario)
        if ($form_data->{collect_payment_method} && $form_data->{setup_intent_id}) {
            # Special case for testing: if we have both flags, go directly to completion
            if ($form_data->{setup_intent_id} =~ /^seti_test/) {
                return $self->handle_setup_completion($db, $run, $form_data);
            }
        }
        
        # Handle setup intent completion
        if ($form_data->{setup_intent_id}) {
            return $self->handle_setup_completion($db, $run, $form_data);
        }
        
        # Handle payment method collection
        if ($form_data->{collect_payment_method}) {
            
            # No Stripe keys configured: provision directly without payment.
            # This handles the test/dev path where no Stripe keys are set.
            if (!$ENV{STRIPE_PUBLISHABLE_KEY} && !$ENV{STRIPE_SECRET_KEY}) {

                # Build a mock subscription record so the run data is consistent
                my $mock_subscription = {
                    stripe_subscription_id => 'sub_test_' . time(),
                    trial_ends_at => time() + (30 * 24 * 60 * 60), # 30 days from now
                    status => 'trialing',
                };

                $run->update_data($db, { subscription => $mock_subscription });

                my $result = $self->_provision_tenant($db, $run);
                return { next_step => 'complete', tenant_created => 1, %$result };
            }
            
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
            organization_name => $org_data->{organization_name} || $run->data->{name} || 'Your Organization',
            subdomain => $org_data->{subdomain} || 'your-org',
            billing_email => $org_data->{billing_email} || $run->data->{billing_email},
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
        # Get selected pricing plan from workflow data
        my $workflow = $self->workflow($db);
        my $run = $workflow->latest_run($db);
        my $selected_plan;

        # Check if we have a run and it has pricing plan data
        if ($run && $run->data && $run->data->{selected_pricing_plan}) {
            $selected_plan = $run->data->{selected_pricing_plan};
        }

        # If no plan selected, fall back to Solo tier defaults. The no-plan case
        # IS the platform Free plan, so the revenue-share rate is read from that
        # seeded plan rather than hardcoded.
        unless ($selected_plan) {
            my $revenue_share_percent = $self->_platform_default_revenue_share_percent($db);
            return {
                plan_name => 'Solo',
                monthly_amount => 0,
                currency => 'usd',
                trial_days => 0,
                revenue_share_percent => $revenue_share_percent,
                description => $revenue_share_percent . '% of processed revenue. No monthly fee.',
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
                formatted_price => 'Free'
            };
        }

        # Use selected plan configuration
        my $config = $selected_plan->{pricing_configuration} || {};
        return {
            plan_name => $selected_plan->{plan_name},
            monthly_amount => $selected_plan->{amount},
            currency => lc($selected_plan->{currency} || 'usd'),
            trial_days => $config->{trial_days} // 30,
            description => $config->{description} || $selected_plan->{plan_name},
            features => $config->{features} || [],
            billing_cycle => $config->{billing_cycle} || 'monthly',
            formatted_price => format_price($selected_plan->{amount}, $selected_plan->{currency}, suffix => '/month')
        };
    }

    # _platform_default_revenue_share_percent: the no-plan ("Free") revenue-share
    # rate as a percent number (e.g. 0 for the Free 0% plan). Delegates to
    # Registry::PriceOps::RevenueShare::platform_default_fraction so the displayed
    # rate reads the SAME source -- and fails loud the same way -- as the
    # charge-time path; a missing Free plan can never make display and charge
    # disagree.
    method _platform_default_revenue_share_percent($db) {
        return Registry::PriceOps::RevenueShare::platform_default_fraction($db) * 100;
    }

    # Price formatting delegated to Registry::Utility::PriceFormat

    method create_setup_intent($db, $run, $form_data) {
        my $subscription_dao = Registry::DAO::Subscription->new(db => $db);
        my $error_handler = Registry::Utility::ErrorHandler->new();
        
        # Get tenant and profile data from workflow
        my $tenant_data = $run->data->{tenant} || {};
        my $profile_data = $run->data->{profile} || {};
        
        # For backward compatibility, also check for flat data structure
        my $billing_email = $profile_data->{billing_email} || $run->data->{billing_email};
        my $organization_name = $profile_data->{organization_name} || $run->data->{name};
        
        # Validate required data
        unless ($billing_email && $organization_name) {
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
                name => $organization_name,
                id => $tenant_data->{id} // 'temp_' . time()
            }, $profile_data);
        };
        
        if ($@ || !$customer) {
            $self->increment_retry_count($db, $run);
            my $error_details = $error_handler->handle_system_error('stripe_customer', $@, {
                organization_name => $organization_name,
                retry_count => $retry_count + 1
            });
            
            $error_handler->log_error($error_details, {
                workflow_id => $run->workflow($db)->id,
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
                    organization_name => $organization_name
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
                workflow_id => $run->workflow($db)->id,
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

        # Test mode: setup_intent_id starts with 'seti_test' — skip Stripe validation.
        if ($form_data->{setup_intent_id} && $form_data->{setup_intent_id} =~ /^seti_test/) {
            my $mock_subscription = {
                stripe_subscription_id => 'sub_test_' . time(),
                trial_ends_at => time() + (30 * 24 * 60 * 60), # 30 days from now
                status => 'trialing',
            };

            $run->update_data($db, { subscription => $mock_subscription });

            my $result = $self->_provision_tenant($db, $run);
            return { next_step => 'complete', tenant_created => 1, %$result };
        }
        
        # For non-test modes, validate the setup_intent_id matches what was stored
        if ($setup_data->{setup_intent_id} && $setup_data->{setup_intent_id} ne $form_data->{setup_intent_id}) {
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

        # Payment successful — provision the tenant and move to completion.
        my $result = $self->_provision_tenant($db, $run);
        return { next_step => 'complete', tenant_created => 1, %$result };
    }

    # _provision_tenant: builds the user list from run data, calls Tenant->provision,
    # sends invitation emails for invite_pending team members, stores tenant info in
    # run data, and returns a result hash with tenant/organization_name/subdomain/
    # admin_email keys.  This is the single provisioning path for all completion
    # scenarios (no-Stripe mock, seti_test mock, real-Stripe).
    method _provision_tenant($db, $run) {
        my $data = $run->data;
        my $profile = $data->{profile} || {};
        my $subscription_data = $data->{subscription} || {};

        # Resolve user list — support both the old 'users' array format and the
        # new admin_*/team_members format stored across workflow steps.
        my @user_data;
        if (exists $data->{users} && ref $data->{users} eq 'ARRAY') {
            # Old format: flat users array stored directly in run data
            @user_data = @{ $data->{users} };
            for my $u (@user_data) { $u->{user_type} //= 'admin' }
        } else {
            # New format: admin_* fields plus optional team_members
            my $admin = {
                name      => $data->{admin_name},
                email     => $data->{admin_email},
                username  => $data->{admin_username},
                user_type => $data->{admin_user_type} || 'admin',
            };
            my $team = $data->{team_members} || [];
            @user_data = ($admin);
            for my $member (@$team) {
                next unless $member->{name} && $member->{email};
                my $username = $member->{email} =~ s/@.*$//r =~ s/[^a-zA-Z0-9]//gr;
                push @user_data, {
                    name          => $member->{name},
                    email         => $member->{email},
                    username      => $username,
                    user_type     => $member->{user_type} || 'staff',
                    invite_pending => 1,
                };
            }
        }

        # Resolve user objects: find existing or create
        my @user_objects;
        for my $ud (@user_data) {
            my $user = Registry::DAO::User->find($db, { username => $ud->{username} })
                    // Registry::DAO::User->find_or_create($db, $ud);
            push @user_objects, $user if $user;
        }

        # Merge subscription billing data into the provision call
        my $org_name = $profile->{name} || $data->{name} || 'Organization';
        my $slug     = $profile->{slug} || $data->{slug};

        my %provision_data = (
            name  => $org_name,
            users => \@user_objects,
        );
        $provision_data{slug} = $slug if $slug;

        # Persist the tenant -> platform plan link when a plan was selected, so
        # the charge-time revenue-share resolver reads the chosen rate.
        $provision_data{platform_pricing_plan_id} = $data->{selected_pricing_plan}{id}
            if $data->{selected_pricing_plan} && $data->{selected_pricing_plan}{id};

        if ($subscription_data->{stripe_subscription_id}) {
            $provision_data{stripe_subscription_id} = $subscription_data->{stripe_subscription_id};
            $provision_data{billing_status}          = 'trial';
            my $trial_ends_at = $subscription_data->{trial_ends_at};
            if ($trial_ends_at && $trial_ends_at =~ /^\d+$/) {
                $trial_ends_at = DateTime->from_epoch(epoch => $trial_ends_at)->iso8601();
            }
            $provision_data{trial_ends_at}           = $trial_ends_at;
            $provision_data{subscription_started_at} = DateTime->now->iso8601();
        } else {
            $provision_data{billing_status}          = 'test';
            $provision_data{subscription_started_at} = DateTime->now->iso8601();
        }

        my $tenant = Registry::DAO::Tenant->provision($db, \%provision_data);

        # Send invitation emails for team members marked invite_pending
        for my $ud (@user_data) {
            next unless $ud->{invite_pending} && $ud->{email};
            my $tenant_user = $tenant->dao($db)->find(User => { username => $ud->{username} });
            if ($tenant_user) {
                $self->_send_invitation_email($db, $tenant, $tenant_user, $ud);
            }
        }

        my $admin_email = $user_data[0]->{email} || $user_data[0]->{username};
        my $result = {
            tenant            => $tenant->id,
            organization_name => $org_name,
            subdomain         => $tenant->slug,
            admin_email       => $admin_email,
            success_timestamp => DateTime->now->iso8601(),
        };

        $run->update_data($db, $result);

        return $result;
    }

    # _send_invitation_email: generates a magic link token for a team member invite
    # and logs the would-be email (actual delivery is a TODO).
    method _send_invitation_email($db, $tenant, $user, $user_data) {
        my ($token, $plaintext) = Registry::DAO::MagicLinkToken->generate($db, {
            user_id    => $user->id,
            purpose    => 'invite',
            expires_in => 168,
        });

        # TODO: Send email with invite link containing $plaintext token
        # The invite link would be: /auth/invite?token=$plaintext
        warn "Would send invitation email to: " . $user_data->{email} .
             " for tenant: " . $tenant->slug .
             " with invite token (token ID: " . $token->id . ")";
    }

    method template { 'tenant-signup/payment' }

    # Provide data for template rendering on GET requests
    method prepare_template_data($db, $run, $params = {}) {
        return $self->prepare_payment_data($db, $run);
    }

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
        
        return;  # No rate limit hit
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
        
        return;  # Session is valid
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
        
        return;  # Service is available
    }
}