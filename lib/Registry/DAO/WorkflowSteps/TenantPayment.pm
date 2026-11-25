# ABOUTME: Signup's commit step: the tenant accepts its chosen platform offer, with no card and no subscription.
# ABOUTME: Provisions the tenant via Tenant->provision when the review page's button is pressed.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::TenantPayment :isa(Registry::DAO::WorkflowStep) {
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
    use Registry::PriceOps::PlatformTerms qw(platform_offers_to_tenants $SOLO_OFFER_ID);
    use Registry::Utility::BaseDomain ();

    use constant SIGNUP_UNAVAILABLE =>
        'Signup is unavailable right now: the platform has no plan on offer. Please try again later.';

    method process($db, $form_data, $run = undef) {
        $run //= do { my $w = $self->workflow($db); $w->latest_run($db) };
        my $error_handler = Registry::Utility::ErrorHandler->new();

        # A second press of the commit button: this run already made its tenant.
        if ( my $done = $self->_provisioned( $db, $run ) ) {
            return { next_step => 'complete', tenant_created => 1, %$done };
        }

        # The choice, refused before any user is written. The review page
        # posts it; a post without one re-checks the one carried. Only listed
        # offers are accepted, and none is listed with a monthly base.
        my $offers = platform_offers_to_tenants($db);
        return { next_step => $self->id, errors => [SIGNUP_UNAVAILABLE] } unless @$offers;
        my $posted = exists $form_data->{offer_version}
            ? $form_data->{offer_version}
            : $run->data->{selected_offer_version};
        my ($chosen) = grep { $_->{id} eq ( $posted // '' ) } @$offers;
        return { next_step => $self->id, errors => ['Please choose one of the plans listed.'] }
            unless $chosen;
        $run->update_data( $db, { selected_offer_version => $chosen->{id} } );

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
        # half-finished key rotation, say -- not a green light. A
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

        # Nothing to collect and nothing to charge: every listed offer has no
        # monthly base -- the platform is paid out of the revenue share on each
        # customer payment -- so the button on the review page is the commit.
        # A card form would only ever total $0.00.
        return $self->_provision_tenant( $db, $run );
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
            billing_summary     => $billing_summary,
            subscription_config => $subscription_config,
        };
    }

    # The offer version the run carries, re-read so a superseded or withdrawn
    # one is never quoted or charged; until one is carried, Solo's current
    # version, which the review page preselects, or the first listed when Solo
    # is not on offer. Undef when nothing
    # is on offer: absence is not zero, so no rate is invented.
    # The run is passed in, never looked up: latest_run is scoped to the
    # workflow alone and would price this signup from someone else's run.
    method chosen_offer ( $db, $run ) {
        my $offers  = platform_offers_to_tenants($db);
        my $carried = ( $run && $run->data || {} )->{selected_offer_version} // '';
        my ($chosen) = grep { $_->{id} eq $carried } @$offers;
        ($chosen) = grep { $_->{offer_id} eq $SOLO_OFFER_ID } @$offers unless $chosen;
        return $chosen // $offers->[0];
    }

    # The quoted and charged terms of the chosen offer version, all from the
    # version's own data; {} when nothing is on offer.
    method get_subscription_config ( $db, $run ) {
        my $offer = $self->chosen_offer( $db, $run ) or return {};
        return $self->_offer_config($offer);
    }

    method _offer_config ($offer) {
        my $amount  = $offer->{amount_cents};
        my $percent = $offer->{fraction} * 100;
        return {
            offer_version_id      => $offer->{id},
            plan_name             => $offer->{name},
            monthly_amount        => $amount,
            currency              => lc $offer->{currency},
            trial_days            => 0,
            revenue_share_percent => $percent,
            description           => format_price( $amount, $offer->{currency} )
                . " a month, $percent% of each payment you take",
            features              => $self->_baseline_features,
            billing_cycle         => 'monthly',
            formatted_price       => $amount
                ? format_price( $amount, $offer->{currency}, suffix => '/month' )
                : 'Free',
        };
    }

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

    # _provision_tenant: builds the user list from run data, calls Tenant->provision,
    # which accepts the run's chosen platform offer for the new tenant, marks
    # team members invite_pending for the admin to invite later, stores tenant
    # info in run data, and returns the step result: complete, with
    # tenant/organization_name/subdomain/admin_email keys, or the review page
    # again re-quoting the offer when the choice is no longer on offer. Users,
    # tenant, schema and entitlement are written in one transaction.
    method _provision_tenant($db, $run) {
        if ( my $done = $self->_provisioned( $db, $run ) ) {
            return { next_step => 'complete', tenant_created => 1, %$done };
        }
        my $data = $run->data;

        # Re-read before any write: only a platform offer to tenants, never its
        # offer to itself or another tenant's; the accept re-checks it is
        # still current under a lock. Its plan is the version's, never the form's.
        my ($offer) = grep { $_->{id} eq ( $data->{selected_offer_version} // '' ) }
            platform_offers_to_tenants($db)->@*;
        return $self->_requote( $db, $run ) unless $offer;
        my $tx = $db->begin;
        my $profile = $data->{profile} || {};

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

        # The new tenant accepts its chosen offer from the moment it exists.
        $provision_data{platform_entitlement} =
            { offer_version_id => $offer->{id}, payment_plan_id => $offer->{plan_id} };

        # No Stripe subscription: the offer has no monthly base and the
        # platform is paid out of the revenue share on each customer payment.
        # The tenant is live, so 'active' -- not 'trial', which would promise an
        # end date that never arrives.
        $provision_data{billing_status}          = 'active';
        $provision_data{subscription_started_at} = DateTime->now->iso8601();

        my $tenant;
        try { $tenant = Registry::DAO::Tenant->provision( $db, \%provision_data ) }
        catch ($e) {
            die $e unless $e isa Registry::DAO::Entitlement::Refused;
            undef $tx;    # rolls back the users and tenant
            return $self->_requote( $db, $run );
        }

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
        $tx->commit;

        return { next_step => 'complete', tenant_created => 1, %$result };
    }

    # The review page again, when the run's choice is no longer on offer: the
    # run now carries its offer's current version, if it has one, so the page
    # quotes those terms for the person to accept again.
    method _requote ( $db, $run ) {
        my $current = $db->query( q{
            SELECT n.id FROM registry.offer_versions o
              JOIN registry.offer_versions n ON n.offer_id = o.offer_id
             WHERE o.id::text = ? AND n.published_at IS NOT NULL AND n.superseded_at IS NULL
        }, $run->data->{selected_offer_version} // '' )->array;
        $run->update_data( $db, { selected_offer_version => $current && $current->[0] } );
        return {
            next_step => $self->id,
            errors    => [ 'The plan you chose has changed or is no longer offered. '
                         . 'Please review the current terms and accept again.' ],
            data      => $self->prepare_payment_data( $db, $run ),
        };
    }

    # The result _provision_tenant stored for $run, when the tenant it names
    # exists: provisioning has already happened for this run.
    method _provisioned ( $db, $run ) {
        my $data = $run->data // {};
        return undef unless $data->{tenant} && !ref $data->{tenant}
            && Registry::DAO::Tenant->find( $db, { id => $data->{tenant} } );
        return { map { $_ => $data->{$_} }
                 qw( tenant organization_name subdomain admin_email success_timestamp ) };
    }

    # Provide data for the review page on GET requests.
    method prepare_template_data($db, $run, $params = {}) {
        my $raw = $run->data || {};
        my @offers = map { $self->_offer_config($_) } platform_offers_to_tenants($db)->@*;

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
            # Every offer to choose between, each quoted from its own version,
            # and the one preselected: what the run carries, else the first.
            offers      => \@offers,
            plan        => $self->get_subscription_config($db, $run),
            unavailable => @offers ? undef : SIGNUP_UNAVAILABLE,
            base_domain => Registry::Utility::BaseDomain::primary_base_domain(),
        };
    }

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
}
