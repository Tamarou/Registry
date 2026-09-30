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
    use Registry::DAO::Notification;
    use Registry::DAO::Workflow;
    use Registry::DAO;
    use Registry::Utility::ErrorHandler;
    use JSON qw(encode_json decode_json);
    use Carp qw(croak);
    use DateTime;
    use Registry::Utility::PriceFormat qw(format_price);
    use Registry::PriceOps::RevenueShare ();
    use Registry::Utility::BaseDomain ();
    use Registry::DAO::PricingPlan;

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
        
        # Absent Stripe keys in production is a misconfiguration -- a
        # half-finished key rotation, say -- not a green light. It used to be
        # checked only on the card-collection branch, which a free plan no
        # longer reaches; checked here it still holds for every signup. A
        # tenant provisioned while the platform cannot reach Stripe is one that
        # can never take a payment, and therefore one we can never earn a
        # revenue share from. Fail closed.
        if (   ( $ENV{MOJO_MODE} // '' ) eq 'production'
            && !$ENV{STRIPE_PUBLISHABLE_KEY}
            && !$ENV{STRIPE_SECRET_KEY} )
        {
            return {
                next_step => $self->id,
                errors    => ['Signup is temporarily unavailable. Please try again shortly.'],
            };
        }

        # How many studios one address may create in an hour.
        #
        # The card used to bound this: #362 made provisioning require a verified
        # SetupIntent, and signup is anonymous by necessity -- you cannot require
        # a login to create an account. With the card gone (#365) the cost is
        # unbounded, and the cost is real: every provisioning clones every table
        # in the schema and claims a subdomain.
        #
        # Identity is deliberately NOT what is being checked. There is no
        # password login, so a tenant whose admin address is not controlled by
        # the person who typed it is inert -- nobody can sign in, nothing can be
        # published, nothing is served. perigrin settled that in #289: an email
        # round-trip is satisfied by a throwaway address anyway, and the
        # verification that matters is Stripe's before any money moves.
        if ( my $error = $self->_provisioning_rate_limited( $db, $run ) ) {
            return { next_step => $self->id, errors => [$error] };
        }

        # A subdomain the applicant asked for and cannot have. Refused here, at
        # the commit, so they are told which word is the problem -- rather than
        # discovering a silent _1 suffix on the confirmation page, or hitting
        # tenants_slug_key as a 500 (#443).
        if ( my $why = $self->_subdomain_unavailable( $db, $run ) ) {
            return { next_step => $self->id, errors => [$why] };
        }

        # Nothing to collect and nothing to charge. Solo has no monthly base
        # -- the platform is paid out of the revenue share on each customer
        # payment -- so the button on this page is the commit, not a step
        # towards a card form that would only ever total $0.00. This is the
        # ordinary path; everything below it is the paid-tier machinery,
        # waiting for a tier with a monthly base to go on sale.
        my $config = $self->get_subscription_config( $db, $run );
        unless ( $config->{monthly_amount} ) {
            my $result = $self->_provision_tenant( $db, $run );
            return { next_step => 'complete', tenant_created => 1, %$result };
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

                # Production already returned above -- absent keys there is a
                # misconfiguration, and reading it as "payment is not required"
                # would turn anonymous signup into a tenant factory: a cloned
                # schema and a live wildcard subdomain on our own TLS per
                # request, plus invitation email to any address the caller
                # names.

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
        my $subscription_config = $self->get_subscription_config($db, $run);
        
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

    # The run is passed in, never looked up: latest_run is scoped to the
    # workflow alone, so re-resolving it here would price this visitor's signup
    # from whichever run on the platform happens to be newest.
    # The selected plan, re-read and re-checked at the moment it matters.
    #
    # validate_plan_selection already refuses a plan that is not a tenant-scoped
    # plan on active offer from the platform, and refuses a coming_soon tier
    # outright -- but it lived only at the moment of selection, guarding the
    # step and nothing after it. This puts the same refusal on the path where
    # the money actually moves.
    #
    # Returns undef when no plan was selected, and also when a selected one no
    # longer resolves. Both then take the Solo/Free default below: a stale or
    # shelved selection charges nothing rather than charging the wrong thing.
    # Refusing the run outright would be stronger still, but get_subscription_config
    # is also called to RENDER the payment page, where an error has nowhere to
    # go -- see #347 for the restructuring that would allow it.
    method resolve_selected_plan ($db, $run) {
        my $selected = $run && $run->data && $run->data->{selected_pricing_plan};

        if ( ref $selected eq 'HASH' && $selected->{id} && !ref $selected->{id} ) {
            my $plan = Registry::DAO::PricingPlan->offered_platform_plan(
                $db, $selected->{id} );
            return $plan if $plan;
        }

        # Nothing chosen, or what was chosen is no longer on offer. Signup no
        # longer asks which plan -- everyone starts on the one the platform
        # sells -- so this is the ordinary path, not the exceptional one.
        # Returning undef here instead would leave platform_pricing_plan_id
        # NULL, and revenue_share_fraction_for_tenant reads a NULL link as the
        # Free plan's 0%: every tenant onboarded free of revenue share, with
        # nothing in the flow to notice.
        return $self->_launch_plan($db);
    }

    method _launch_plan ($db) {
        my $id = Registry::PriceOps::RevenueShare::platform_launch_plan_id($db);
        return Registry::DAO::PricingPlan->offered_platform_plan( $db, $id );
    }

    method get_subscription_config($db, $run) {
        # Run data carries a plan ID and nothing else worth trusting. The
        # snapshot stored at selection -- plan_name, amount_cents, currency --
        # was handed straight to Stripe as items[0][price_data][unit_amount],
        # so a signup started before a price change and resumed after it charged
        # the remembered amount while linking the plan whose rate had moved.
        # Displayed, charged and linked could disagree with nobody doing
        # anything wrong.
        my $plan = $self->resolve_selected_plan($db, $run);
        my $selected_plan = $plan && {
            id                    => $plan->id,
            plan_name             => $plan->plan_name,
            amount_cents          => $plan->amount_cents,
            currency              => $plan->currency,
            pricing_configuration => $plan->pricing_configuration,
            metadata              => $plan->metadata,
        };

        # Reached only when no plan resolves at all -- the launch plan is
        # missing its active platform relationship, or is marked coming_soon.
        # That is a misconfiguration, and the signup page says as little as it
        # can truthfully say rather than inventing a rate.
        unless ($selected_plan) {
            my $revenue_share_percent = $self->_platform_default_revenue_share_percent($db);
            return {
                plan_name => 'Solo',
                monthly_amount => 0,
                currency => 'usd',
                trial_days => 0,
                revenue_share_percent => $revenue_share_percent,
                description => $revenue_share_percent . '% of processed revenue. No monthly fee.',
                features => $self->_baseline_features,
                billing_cycle => 'monthly',
                formatted_price => 'Free'
            };
        }

        # Use selected plan configuration.
        #
        # A plan declares its own trial length; silence means no trial. The old
        # default of 30 handed a free plan a free trial -- Solo costs $0 and
        # always will, so "your trial ends March 4th" was both meaningless and
        # alarming, and the copy that quoted it ran all the way to the
        # confirmation page.
        my $config = $selected_plan->{pricing_configuration} || {};
        my $amount = $selected_plan->{amount_cents};
        return {
            plan_name => $selected_plan->{plan_name},
            monthly_amount => $amount,
            currency => lc($selected_plan->{currency} || 'usd'),
            trial_days => $config->{trial_days} // 0,
            revenue_share_percent => ( $config->{percentage} // 0 ) * 100,
            description => $config->{description} || $selected_plan->{plan_name},
            features => $config->{features} || $self->_baseline_features,
            billing_cycle => $config->{billing_cycle} || 'monthly',
            formatted_price => $amount
                ? format_price($amount, $selected_plan->{currency}, suffix => '/month')
                : 'Free'
        };
    }

    # _platform_default_revenue_share_percent: the no-plan ("Free") revenue-share
    # rate as a percent number (e.g. 0 for the Free 0% plan). Delegates to
    # Registry::PriceOps::RevenueShare::platform_default_fraction so the displayed
    # rate reads the SAME source -- and fails loud the same way -- as the
    # charge-time path; a missing Free plan can never make display and charge
    # disagree.
    # Twenty, not five. Five bounds the cost just as well and breaks legitimate
    # bursts: a school district behind one NAT signing up a few sites, or the
    # Playwright suite, which shares one database across a run and provisions a
    # dozen tenants from the loopback address. Twenty clones an hour from one
    # address is still a bound; the abuse this exists for is orders of magnitude
    # above it.
    # Why the applicant cannot have the subdomain they typed, or undef.
    #
    # Only for a subdomain they CHOSE. A derived one is suffixed to something
    # free by available_slug_for_name, and refusing a name nobody asked for
    # would be a dead end rather than a correction.
    method _subdomain_unavailable ( $db, $run ) {
        my $data = $run->data || {};
        my $typed = $data->{subdomain} // '';
        return undef unless length $typed;

        my $slug = Registry::DAO::Tenant->slug_for_name($typed);

        return "'$slug' is reserved for the platform. Please choose another web address."
            if Registry::DAO::Tenant->slug_is_reserved($slug);

        return "'$slug' is already taken. Please choose another web address."
            if Registry::DAO::Tenant->slug_exists( $db, $slug );

        return undef;
    }

    use constant PROVISIONINGS_PER_HOUR => 20;

    # Returns a message when the caller has provisioned too many studios lately,
    # or undef.
    #
    # Counted from registry.tenants itself rather than from a separate attempts
    # table, so the thing being bounded is exactly the thing recorded and the two
    # cannot drift. Registry::Middleware::RateLimit cannot serve here: its
    # counters live in one process's memory, reset on restart, are not shared
    # between instances, and are keyed per-address across all paths at 100/min --
    # which is 100 schema clones a minute.
    method _provisioning_rate_limited ( $db, $run ) {
        # Production only. There is no adversary in a test or on a developer's
        # machine, and both legitimately provision in bursts -- the Playwright
        # suite shares one database across its whole run. Gating here rather
        # than raising the number high enough to hide the control is the
        # honest shape, and t/security/provisioning-rate-limit.t sets
        # MOJO_MODE=production so the guard is still exercised rather than
        # merely present.
        return undef unless ( $ENV{MOJO_MODE} // '' ) eq 'production';

        my $ip = ( $run->data || {} )->{__remote_address} or return undef;

        my $recent = $db->query( q{
            SELECT count(*) AS n
              FROM registry.tenants
             WHERE created_from_ip = ?
               AND created_at > now() - interval '1 hour'
        }, $ip )->hash->{n};

        return undef if $recent < PROVISIONINGS_PER_HOUR;

        return 'Too many organizations have been created from this connection '
             . 'in the last hour. Please try again later, or contact support if '
             . 'you need several set up at once.';
    }

    # What every tier includes. Lives here rather than in the plan row because
    # it is the same list for all of them -- a plan that genuinely offers more
    # says so in its own pricing_configuration->>'features' and overrides this.
    method _baseline_features {
        return [
            'Unlimited student enrollments',
            'Attendance tracking and reporting',
            'Parent communication tools',
            'Payment processing',
            'Waitlist management',
            'Staff scheduling',
            'Custom reporting'
        ];
    }

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

        # Two dependent Stripe calls. Each keeps the error branch it had; the
        # eval blocks became ->catch, because Registry::Service::Stripe rejects
        # where the old client warned and returned undef.
        my $customer;

        return $subscription_dao->create_customer_async({
            name => $organization_name,
            id => $tenant_data->{id} // 'temp_' . time()
        }, $profile_data)->catch(sub ($err) {
            $self->increment_retry_count($db, $run);
            my $error_details = $error_handler->handle_system_error('stripe_customer', $err, {
                organization_name => $organization_name,
                retry_count => $retry_count + 1
            });

            $error_handler->log_error($error_details, {
                workflow_id => $run->workflow($db)->id,
                run_id => $run->id,
                step => 'create_customer'
            });

            # A step result, not a rethrow: the chain below checks for it and
            # stops, so the customer failure is answered with its own message
            # rather than the setup-intent one.
            return {
                next_step => $self->id,
                errors => [$error_details->{user_message}],
                data => $self->prepare_payment_data($db, $run),
                retry_count => $retry_count + 1,
                retry_delay => $error_details->{retry_delay}
            };
        })->then(sub ($result) {
            return $result if ref $result eq 'HASH' && $result->{errors};
            $customer = $result;

            return $subscription_dao->create_setup_intent_async($customer->{id}, {
                usage => 'off_session',
                metadata => {
                    tenant_workflow => $run->id,
                    organization_name => $organization_name
                }
            });
        })->then(sub ($setup_intent) {
            return $setup_intent if ref $setup_intent eq 'HASH' && $setup_intent->{errors};

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
        })->catch(sub ($err) {
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
        });
    }

    method handle_setup_completion($db, $run, $form_data) {
        my $subscription_dao = Registry::DAO::Subscription->new(db => $db);
        my $setup_data = $run->data->{payment_setup} || {};

        # The run must carry the setup intent it created. This check used to be
        # folded into the comparison below, which meant a run that never reached
        # create_setup_intent skipped it entirely -- leaving only Stripe's own
        # lookup, and that resolves an intent belonging to any OTHER run on this
        # account just as happily. Payment for one signup must not complete a
        # different one.
        unless ( $setup_data->{setup_intent_id} ) {
            return {
                next_step => $self->id,
                errors    => ['Payment setup was not started for this signup. Please start again.'],
                data      => $self->prepare_payment_data($db, $run),
            };
        }

        # Validate the setup_intent_id matches what was stored
        if ($setup_data->{setup_intent_id} ne $form_data->{setup_intent_id}) {
            return {
                next_step => $self->id,
                errors => ['Invalid payment setup. Please try again.'],
                data => $self->prepare_payment_data($db, $run)
            };
        }

        # Retrieve and verify the setup intent, then create the subscription.
        # Two dependent Stripe calls; the eval blocks became ->catch, because
        # Registry::Service::Stripe rejects where the old client returned undef.
        my $setup_failed = sub ($setup_intent = undef) {
            my $error_msg = 'Payment method setup failed.';
            if ($setup_intent && $setup_intent->{last_setup_error}) {
                $error_msg .= ' ' . $setup_intent->{last_setup_error}->{message};
            }

            return {
                next_step => $self->id,
                errors => [$error_msg],
                data => $self->prepare_payment_data($db, $run)
            };
        };

        # Each ->catch sits directly on the call it answers, not at the end of
        # the chain. A trailing catch would also swallow a _provision_tenant
        # failure and report it as a payment problem, which is the one thing
        # this step must not do: the schema is what the money bought.
        return $subscription_dao->get_setup_intent_async($form_data->{setup_intent_id})
            ->catch(sub ($err) { $setup_failed->() })
            ->then(sub ($setup_intent) {
                return $setup_intent
                    if ref $setup_intent eq 'HASH' && $setup_intent->{errors};

                # A setup intent that exists but did not succeed is a failure
                # with a message of its own, so it is graded here rather than
                # left to the ->catch below.
                return $setup_failed->($setup_intent)
                    unless $setup_intent && ($setup_intent->{status} // '') eq 'succeeded';

                my $config = $self->get_subscription_config($db, $run);

                return $subscription_dao->create_subscription_with_config_async(
                    $setup_data->{stripe_customer_id},
                    $setup_intent->{payment_method},
                    $config
                )->catch(sub ($err) {
                    return {
                        next_step => $self->id,
                        errors => ['Failed to create subscription. Please contact support.'],
                        data => $self->prepare_payment_data($db, $run)
                    };
                })->then(sub ($subscription) {
                    return $subscription
                        if ref $subscription eq 'HASH' && $subscription->{errors};

                    # Store subscription info in workflow data
                    $run->update_data($db, {
                        subscription => {
                            stripe_subscription_id => $subscription->{id},
                            trial_ends_at => $subscription->{trial_end},
                            status => $subscription->{status}
                        }
                    });

                    # Payment successful -- provision the tenant and move to
                    # completion.
                    # Outside every catch above, deliberately: a provisioning
                    # failure is not a payment failure and must not be reported
                    # as one.
                    my $result = $self->_provision_tenant($db, $run);
                    return { next_step => 'complete', tenant_created => 1, %$result };
                });
            });
    }

    # _provision_tenant: builds the user list from run data, calls Tenant->provision,
    # marks team members invite_pending for the admin to invite later, stores
    # tenant info in run data, and returns a result hash with
    # tenant/organization_name/subdomain/admin_email keys.  This is the single
    # provisioning path for all completion scenarios (no-Stripe mock, real-Stripe).
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

        # A subdomain the applicant typed is their choosing, and it wins over
        # deriving one from the organisation name. Normalised rather than taken
        # verbatim, because the box accepts "Clay Studio" and a slug is a schema
        # name (#443).
        my $slug = $profile->{slug} || $data->{slug};
        if ( !$slug && ( $data->{subdomain} // '' ) ne '' ) {
            $slug = Registry::DAO::Tenant->slug_for_name( $data->{subdomain} );
        }

        my %provision_data = (
            name  => $org_name,
            users => \@user_objects,
        );

        # Server-derived, from _apply_server_owned_data -- see the rate limit
        # above, and the note there about why a client-supplied address would be
        # a limit the client sets for itself.
        $provision_data{created_from_ip} = $data->{__remote_address}
            if $data->{__remote_address};
        $provision_data{slug} = $slug if $slug;

        # Persist the tenant -> platform plan link when a plan was selected, so
        # the charge-time revenue-share resolver reads the chosen rate.
        # The plan the charge resolved to, not the one run data remembers -- the
        # tenants row is the charge-time rate authority, so linking a different
        # plan than was billed is the divergence this guards against.
        my $resolved_plan = $self->resolve_selected_plan( $db, $run );
        $provision_data{platform_pricing_plan_id} = $resolved_plan->id if $resolved_plan;

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
            # No Stripe subscription because there is nothing to subscribe to:
            # the plan has no monthly base and the platform is paid out of the
            # revenue share on each customer payment. The tenant is live, so
            # 'active' -- not 'trial', which would promise an end date that
            # never arrives. ('test' used to go here and is not one of the five
            # values tenants_billing_status_check allows; the insert died. It
            # never fired before because signup always minted a subscription,
            # real or mock.)
            $provision_data{billing_status}          = 'active';
            $provision_data{subscription_started_at} = DateTime->now->iso8601();
        }

        my $tenant = Registry::DAO::Tenant->provision($db, \%provision_data);

        # Deliberately NOT sending the invitations here.
        #
        # Signup is anonymous, the team-member addresses are whatever the caller
        # typed on the form, and delivery is real now -- Postmark in production.
        # Mailing them made an unauthenticated form into an outbound mailer for
        # attacker-chosen recipients, carrying our sending domain and a working
        # magic link into a tenant the recipient never asked to join (#438).
        # #289 said this became real "the day that TODO is implemented". It did.
        #
        # The people are still created, marked invite_pending, and the admin
        # sends their invitations from /admin/people once signed in -- which is
        # itself proof they hold the address the tenant was created with. Nothing
        # leaves the building on an anonymous request.

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

    method template { 'tenant-signup/payment' }

    # Provide data for template rendering on GET requests.
    #
    # One step class now backs two pages -- the review page a free signup ends
    # on, and the payment page a paid tier would need -- so this returns what
    # both templates read and lets each take its half.
    method prepare_template_data($db, $run, $params = {}) {
        my $raw = $run->data || {};

        return {
            %{ $self->prepare_payment_data($db, $run) },

            profile => {
                name          => $raw->{name} || $raw->{organization_name},
                # The slug provisioning will actually derive, not the literal
                # 'organization' the template used to fall back to. The review
                # page names the URL the studio is about to live at; it has to
                # be the one it gets.
                subdomain     => $raw->{subdomain}
                    || $raw->{slug}
                    || Registry::DAO::Tenant->available_slug_for_name(
                           $db, $raw->{name} || $raw->{organization_name} || '' ),
                description   => $raw->{description},
                billing_email => $raw->{billing_email},
            },
            team => {
                admin => {
                    name     => $raw->{admin_name},
                    email    => $raw->{admin_email},
                    username => $raw->{admin_username},
                },
                team_members => $raw->{team_members} || [],
            },
            # The plan nobody was asked to choose, resolved by the same code
            # that provisions -- so the page states the terms the tenant is
            # actually about to be put on.
            plan        => $self->get_subscription_config($db, $run),
            base_domain => Registry::Utility::BaseDomain::primary_base_domain(),
        };
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