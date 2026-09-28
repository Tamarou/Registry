# ABOUTME: Admin screen and routes for Stripe Connect onboarding, which is how a
# ABOUTME: tenant becomes able to take money and therefore how the platform earns.
use 5.42.0;
use utf8;
use Object::Pad;

class Registry::Controller::StripeConnect :isa(Registry::Controller) {
    use Registry::DAO;
    use Registry::DAO::Tenant;
    use Registry::Service::Stripe;
    use Registry::Utility::BaseDomain ();

    # Standard, not Express or Custom: the tenant owns their Stripe account and
    # their relationship with Stripe, which is the thing Registry sells against
    # platforms that hold the money. The charge model is unaffected -- destination
    # charges with on_behalf_of and an application_fee_amount work the same way.
    use constant ACCOUNT_TYPE => 'standard';

    # tenant_domains and tenants live in the registry schema; the dao helper is
    # used rather than a direct connection so tests can override it.
    method _registry_dao { return $self->dao('registry') }

    method _tenant ($db) {
        return Registry::DAO::Tenant->find( $db, { slug => $self->tenant } );
    }

    # Absolute URLs, because Stripe redirects the browser back here from its own
    # domain. Built from the tenant's own host so the return lands in the schema
    # the account belongs to.
    method _url_for_tenant ($path) {
        return Registry::Utility::BaseDomain::tenant_url( $self->tenant, $path );
    }

    # GET /admin/billing
    method index {
        my $db = $self->_registry_dao->db;
        my $tenant = $self->_tenant($db)
            or return $self->render( text => 'Tenant not found', status => 404 );

        return $self->_render_status($tenant);
    }

    # not_started -> in_progress -> ready. The middle state is real and common:
    # Stripe onboarding can be abandoned halfway, and an account that exists but
    # has not submitted details still cannot take a payment.
    method _status ($tenant) {
        return 'not_started' unless $tenant->stripe_connect_account_id;
        return 'ready'       if $tenant->stripe_connect_ready;
        return 'in_progress';
    }

    # POST /admin/billing/connect -- create the account if there is not one yet,
    # then send the tenant to Stripe to finish it.
    #
    # Async throughout, and not as a style choice: these run inside the daemon's
    # event loop, where the synchronous wrappers cannot settle and die saying so.
    method start {
        my $db = $self->_registry_dao->db;
        my $tenant = $self->_tenant($db)
            or return $self->render( text => 'Tenant not found', status => 404 );

        if ( my $account_id = $tenant->stripe_connect_account_id ) {
            return $self->_redirect_to_onboarding( $tenant, $account_id );
        }

        my $stripe = $self->_stripe($tenant) or return;

        $self->render_later;
        return $stripe->create_account_async({
            type                     => ACCOUNT_TYPE,
            'business_profile[name]' => $tenant->name,
            'metadata[tenant_slug]'  => $tenant->slug,
        })->then( sub ($account) {
            # Persisted before the redirect, deliberately. The account exists at
            # Stripe the moment that call returns; losing the id here would
            # orphan it and mint a second one on the next attempt, and the
            # webhook that mirrors capabilities matches tenants by this column.
            my $updated = $tenant->update( $db,
                { stripe_connect_account_id => $account->{id} } );
            return $self->_redirect_to_onboarding( $updated, $account->{id} );
        })->catch( sub ($error) {
            $self->log->error("Stripe Connect account creation failed for "
                . $tenant->slug . ": $error");
            $self->_render_error($tenant,
                'Stripe could not be reached. Please try again in a moment.');
        });
    }

    # GET /admin/billing/refresh -- where Stripe sends a caller whose link has
    # expired. Links are single-use and short-lived, so this mints another.
    method refresh {
        my $db = $self->_registry_dao->db;
        my $tenant = $self->_tenant($db)
            or return $self->render( text => 'Tenant not found', status => 404 );

        my $account_id = $tenant->stripe_connect_account_id
            or return $self->redirect_to('admin_billing');

        return $self->_redirect_to_onboarding( $tenant, $account_id );
    }

    method _redirect_to_onboarding ( $tenant, $account_id ) {
        my $stripe = $self->_stripe($tenant) or return;

        $self->render_later;
        return $stripe->create_account_link_async({
            account     => $account_id,
            type        => 'account_onboarding',
            refresh_url => $self->_url_for_tenant('/admin/billing/refresh'),
            return_url  => $self->_url_for_tenant('/admin/billing/return'),
        })->then( sub ($link) {
            $self->redirect_to( $link->{url} );
        })->catch( sub ($error) {
            $self->log->error("Stripe Connect account link failed for "
                . $tenant->slug . ": $error");
            $self->_render_error($tenant,
                'Stripe could not be reached. Please try again in a moment.');
        });
    }

    # GET /admin/billing/return -- Stripe sends the tenant back here when they
    # finish or abandon onboarding.
    #
    # The account.updated webhook mirrors capabilities too, but arrives whenever
    # it arrives, and a developer running without a webhook endpoint never sees
    # one at all. Reading the account here means the page the tenant lands on
    # tells them the truth.
    method finish {
        my $db = $self->_registry_dao->db;
        my $tenant = $self->_tenant($db)
            or return $self->render( text => 'Tenant not found', status => 404 );

        my $account_id = $tenant->stripe_connect_account_id
            or return $self->_render_status($tenant);

        my $stripe = $self->_stripe($tenant) or return;

        $self->render_later;
        return $stripe->retrieve_account_async($account_id)->then( sub ($account) {
            my $updated = $tenant->update( $db, {
                stripe_charges_enabled   => $account->{charges_enabled}   ? 1 : 0,
                stripe_details_submitted => $account->{details_submitted} ? 1 : 0,
            } );
            $self->_render_status($updated);
        })->catch( sub ($error) {
            # A failed read is not evidence about the account, so the row is left
            # alone and the page reports what is on it.
            $self->log->error("Stripe Connect account retrieval failed for "
                . $tenant->slug . ": $error");
            $self->_render_status($tenant);
        });
    }

    # The client, or undef having already rendered. STRIPE_SECRET_KEY missing is
    # a deployment fault, not something to show the tenant a stack trace over.
    #
    # Parked in the stash so it outlives the action. The client owns its
    # Mojo::UserAgent, the promise callbacks do not close over the client, and a
    # UA freed while its request is in flight drops the connection -- which
    # surfaces as "Premature connection close" from Stripe rather than as
    # anything resembling a lifetime bug.
    method _stripe ($tenant) {
        return $self->stash('_stripe_client') if $self->stash('_stripe_client');

        my $stripe = eval { Registry::Service::Stripe->from_env };
        if ($stripe) {
            $self->stash( _stripe_client => $stripe );
            return $stripe;
        }

        $self->log->error("Stripe client unavailable for " . $tenant->slug . ": $@");
        $self->_render_error($tenant,
            'Payments are not configured on this server yet.');
        return undef;
    }

    method _render_status ($tenant) {
        return $self->render(
            template => 'admin/billing/index',
            tenant   => $tenant,
            status_  => $self->_status($tenant),
        );
    }

    method _render_error ( $tenant, $message ) {
        return $self->render(
            template => 'admin/billing/index',
            tenant   => $tenant,
            status_  => $self->_status($tenant),
            error    => $message,
            status   => 502,
        );
    }
}
