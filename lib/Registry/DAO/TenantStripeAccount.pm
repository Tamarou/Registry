# ABOUTME: DAO for Stripe Connect account state per tenant.
# ABOUTME: Tracks onboarding status, charges_enabled, and provides the stripe_account_id for direct charges.
use 5.42.0;
use Object::Pad;

class Registry::DAO::TenantStripeAccount :isa(Registry::DAO::Object) {
    use Carp qw(croak);

    field $id :param :reader = undef;
    field $tenant_id :param :reader;
    field $stripe_account_id :param :reader;
    field $onboarding_status :param :reader = 'not_started';
    field $charges_enabled :param :reader = 0;
    field $payouts_enabled :param :reader = 0;
    field $details_submitted :param :reader = 0;
    field $account_type :param :reader = 'standard';
    field $metadata :param :reader = {};
    field $created_at :param :reader = undef;
    field $updated_at :param :reader = undef;

    # Review fix #3: use registry. schema prefix
    sub table { 'registry.tenant_stripe_accounts' }

    sub create ($class, $db, $data) {
        for my $field (qw(metadata)) {
            next unless exists $data->{$field};
            $data->{$field} = { -json => $data->{$field} };
        }
        $class->SUPER::create($db, $data);
    }

    # Review fix #6: find_by_tenant must be sub, not method
    sub find_by_tenant ($class, $db, $tenant_id) {
        $class->find($db, { tenant_id => $tenant_id });
    }

    method update_from_stripe ($db, $stripe_data) {
        my $new_charges = $stripe_data->{charges_enabled} ? 1 : 0;
        my $new_payouts = $stripe_data->{payouts_enabled} ? 1 : 0;
        my $new_details = $stripe_data->{details_submitted} ? 1 : 0;

        # Derive onboarding status from Stripe account state
        my $new_status;
        if ($new_charges && $new_details) {
            $new_status = 'complete';
        } elsif ($new_details) {
            $new_status = 'pending';
        } else {
            $new_status = 'not_started';
        }

        $self->update($db, {
            charges_enabled => $new_charges,
            payouts_enabled => $new_payouts,
            details_submitted => $new_details,
            onboarding_status => $new_status,
            updated_at => \'CURRENT_TIMESTAMP',
        });

        # Update in-memory fields
        $charges_enabled = $new_charges;
        $payouts_enabled = $new_payouts;
        $details_submitted = $new_details;
        $onboarding_status = $new_status;
    }

    method can_accept_payments () {
        return $charges_enabled ? 1 : 0;
    }
}

1;
