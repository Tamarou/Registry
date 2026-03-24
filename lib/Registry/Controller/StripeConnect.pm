# ABOUTME: Controller for Stripe Connect onboarding and account management.
# ABOUTME: Handles onboarding link creation, return from Stripe, and status display.
use 5.42.0;
use Object::Pad;

class Registry::Controller::StripeConnect :isa(Registry::Controller) {
    use Registry::DAO::TenantStripeAccount;
    use Registry::DAO::Tenant;

    method onboard {
        my $dao = $self->app->dao;
        my $tenant_id = $self->param('tenant_id');

        my $account = Registry::DAO::TenantStripeAccount->find_by_tenant($dao->db, $tenant_id);
        unless ($account) {
            return $self->render(text => 'No Stripe account found for tenant', status => 404);
        }

        # If already onboarded, show status
        if ($account->onboarding_status eq 'complete') {
            return $self->redirect_to($self->url_for('connect_status', tenant_id => $tenant_id));
        }

        # Try to create onboarding link via Stripe API
        unless ($ENV{STRIPE_SECRET_KEY}) {
            return $self->render(
                template => 'admin/settings/stripe-connect',
                account => $account,
                tenant_id => $tenant_id,
                error => 'Stripe is not configured. Contact platform support.',
            );
        }

        # Review fix #4: check env BEFORE instantiating Client::Stripe
        require Registry::Client::Stripe;
        my $client = Registry::Client::Stripe->new();
        my $return_url = $self->url_for('connect_return', tenant_id => $tenant_id)->to_abs->to_string;
        my $refresh_url = $self->url_for('connect_onboard', tenant_id => $tenant_id)->to_abs->to_string;

        my $link = eval {
            $client->create_onboarding_link(
                $account->stripe_account_id,
                $return_url,
                $refresh_url,
            );
        };

        if ($@ || !$link) {
            return $self->render(
                template => 'admin/settings/stripe-connect',
                account => $account,
                tenant_id => $tenant_id,
                error => 'Failed to create onboarding link. Please try again.',
            );
        }

        return $self->redirect_to($link->{url});
    }

    method return_from_stripe {
        my $dao = $self->app->dao;
        my $tenant_id = $self->param('tenant_id');

        my $account = Registry::DAO::TenantStripeAccount->find_by_tenant($dao->db, $tenant_id);
        unless ($account) {
            return $self->render(text => 'No Stripe account found', status => 404);
        }

        # Check-on-return: fetch current account status from Stripe API
        if ($ENV{STRIPE_SECRET_KEY}) {
            require Registry::Client::Stripe;
            my $client = Registry::Client::Stripe->new();
            my $stripe_account = eval {
                $client->retrieve_connect_account($account->stripe_account_id);
            };

            if ($stripe_account && !$@) {
                $account->update_from_stripe($dao->db, {
                    charges_enabled => $stripe_account->{charges_enabled},
                    payouts_enabled => $stripe_account->{payouts_enabled},
                    details_submitted => $stripe_account->{details_submitted},
                });
                # Re-fetch updated record
                $account = Registry::DAO::TenantStripeAccount->find_by_tenant($dao->db, $tenant_id);
            }
        }

        return $self->render(
            template => 'admin/settings/stripe-connect',
            account => $account,
            tenant_id => $tenant_id,
        );
    }

    method status {
        my $dao = $self->app->dao;
        my $tenant_id = $self->param('tenant_id');

        my $account = Registry::DAO::TenantStripeAccount->find_by_tenant($dao->db, $tenant_id);

        return $self->render(
            template => 'admin/settings/stripe-connect',
            account => $account,
            tenant_id => $tenant_id,
        );
    }
}

1;
