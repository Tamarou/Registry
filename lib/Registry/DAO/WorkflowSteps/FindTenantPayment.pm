# ABOUTME: platform-fee-refund-exception step: an admin of a tenant holding the operator right names a tenant and one of its payments.
# ABOUTME: Its locate check is asked again by every later step: who is acting, the tenant, the payment, and that its fee may come back.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::FindTenantPayment :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Tenant;
    use Registry::DAO::Payment;

    my $UUID = qr/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i;

    # Why $data's user, acting as $data's tenant, may not reach other tenants'
    # payments, or undef. The operator right: an admin of the tenant acted as,
    # which must hold `operator` (an admin of the platform acting as a studio
    # is refused, because the studio holds no such right).
    sub operator_refusal ( $class, $db, $data ) {
        my $refused = 'Only an admin of the platform tenant may apply the fee-refund exception';
        my $acting  = Registry::DAO::Tenant->find( $db, { slug => $data->{__tenant_slug} // '' } )
            or return $refused;
        return $refused
            unless ( Registry::DAO::Tenant->role_in( $db, $acting->slug, $data->{user_id} ) // '' ) eq 'admin'
                && Registry::DAO::Tenant->holds( $db, $acting->id, 'operator' );
        return;
    }

    # The payment $slug's tenant made with id $payment_id, once everything
    # that must hold before its fee can be returned does:
    #   { tenant, payment, terms, remaining_cents } or { error }.
    # The slug must be a registry.tenants row before any schema is connected,
    # because it becomes a search_path.
    sub locate ( $class, $db, $data, $slug, $payment_id ) {
        if ( my $why = $class->operator_refusal( $db, $data ) ) { return { error => $why } }

        my $tenant = defined $slug && !ref $slug && length $slug
            && Registry::DAO::Tenant->find( $db, { slug => $slug } );
        return { error => 'There is no tenant with that slug' } unless $tenant;

        my $payment = defined $payment_id && !ref $payment_id && $payment_id =~ $UUID
            && Registry::DAO::Payment->find( $tenant->dao->db, { id => $payment_id } );
        return { error => 'That tenant has no payment with that id' } unless $payment;

        return { error => 'That payment has not been refunded' }
            unless Registry::DAO::Payment->_money_returned( $payment->status );

        my $terms = eval { $payment->stamped_platform_terms($db) };
        return { error => 'That payment was not charged under platform terms that allow the fee to be returned' }
            unless $terms && ( ( $terms->{refund_policy} // {} )->{kind} // '' ) eq 'keep_fee_with_admin_exception';

        my $remaining = ( $payment->platform_fee_cents // 0 ) - ( $payment->platform_fee_refunded_cents // 0 );
        return { error => 'None of the platform fee on that payment is left to return' }
            unless $remaining > 0;

        return { tenant => $tenant, payment => $payment, terms => $terms, remaining_cents => $remaining };
    }

    # The located payment for the run $data belongs to, as the later steps
    # and screens ask it.
    sub located ( $class, $db, $data, $run ) {
        my $found = $run ? $run->data->{fee_refund_payment} // {} : {};
        return $class->locate( $db, $data, $found->{tenant}, $found->{payment_id} );
    }

    method process ( $db, $form_data, $run = undef ) {
        my $found = $self->locate( $db, $form_data, $form_data->{payment_tenant}, $form_data->{payment_id} );
        return { stay => 1, errors => [ $found->{error} ] } if $found->{error};
        # What the later screens show; every later step locates the payment afresh.
        return { fee_refund_payment => {
            tenant          => $found->{tenant}->slug,
            tenant_name     => $found->{tenant}->name,
            payment_id      => $found->{payment}->id,
            amount_cents    => $found->{payment}->amount_cents,
            fee_cents       => $found->{payment}->platform_fee_cents,
            remaining_cents => $found->{remaining_cents},
            terms_name      => ( $found->{terms} // {} )->{name},
        } };
    }
}

1;
