# ABOUTME: High-level Stripe client for payment and subscription management
# ABOUTME: Provides business-focused methods using Registry::Service::Stripe
use 5.40.2;
use warnings;
use experimental 'signatures', 'try', 'builtin';

use Object::Pad;
class Registry::Client::Stripe {

use Registry::Service::Stripe;

field $stripe_service :param = undef;

ADJUST {
    # Initialize Stripe service if not provided
    unless ($stripe_service) {
        my $api_key = $ENV{STRIPE_SECRET_KEY} || die "STRIPE_SECRET_KEY not set";
        my $webhook_secret = $ENV{STRIPE_WEBHOOK_SECRET};

        $stripe_service = Registry::Service::Stripe->new(
            api_key => $api_key,
            webhook_secret => $webhook_secret,
        );
    }
}

# Payment Intent Operations
method create_payment_intent ($args) {
    return $stripe_service->create_payment_intent($args);
}

method retrieve_payment_intent ($intent_id) {
    return $stripe_service->retrieve_payment_intent($intent_id);
}

method confirm_payment_intent ($intent_id, $args = {}) {
    return $stripe_service->confirm_payment_intent($intent_id, $args);
}

# Customer Operations
method create_customer ($args) {
    return $stripe_service->create_customer($args);
}

method retrieve_customer ($customer_id) {
    return $stripe_service->retrieve_customer($customer_id);
}

method update_customer ($customer_id, $args) {
    return $stripe_service->update_customer($customer_id, $args);
}

# Subscription Operations for Payment Schedules
method create_subscription ($args) {
    return $stripe_service->create_subscription($args);
}

method retrieve_subscription ($subscription_id) {
    return $stripe_service->retrieve_subscription($subscription_id);
}

method update_subscription ($subscription_id, $args) {
    return $stripe_service->update_subscription($subscription_id, $args);
}

method cancel_subscription ($subscription_id, $args = {}) {
    return $stripe_service->cancel_subscription($subscription_id, $args);
}

# Invoice Operations for Subscription Tracking
method list_invoices ($args = {}) {
    return $stripe_service->list_invoices($args);
}

method retrieve_invoice ($invoice_id) {
    return $stripe_service->retrieve_invoice($invoice_id);
}

# Payment Method Operations
method create_payment_method ($args) {
    return $stripe_service->create_payment_method($args);
}

method attach_payment_method ($pm_id, $customer_id) {
    return $stripe_service->attach_payment_method($pm_id, $customer_id);
}

method list_customer_payment_methods ($customer_id, $type = 'card') {
    return $stripe_service->list_customer_payment_methods($customer_id, $type);
}

# Refund Operations
method create_refund ($args) {
    return $stripe_service->create_refund($args);
}

# Webhook Verification
method verify_webhook_signature ($payload, $signature_header) {
    return $stripe_service->verify_webhook_signature($payload, $signature_header);
}

# Business Logic Methods for Payment Schedules

method create_installment_subscription ($args) {
    my $customer_id = $args->{customer_id} || die "customer_id required";
    my $payment_method_id = $args->{payment_method_id} || die "payment_method_id required";
    my $amount_cents = $args->{amount_cents} || die "amount_cents required";
    my $interval = $args->{interval} || 'month';
    my $interval_count = $args->{interval_count} || 1;
    my $description = $args->{description} || 'Installment Payment';
    my $metadata = $args->{metadata} || {};

    return $self->create_subscription({
        customer => $customer_id,
        default_payment_method => $payment_method_id,
        items => [{
            price_data => {
                currency => 'usd',
                product_data => {
                    name => $description,
                },
                unit_amount => $amount_cents,
                recurring => {
                    interval => $interval,
                    interval_count => $interval_count,
                },
            },
            quantity => 1,
        }],
        metadata => $metadata,
    });
}

method pause_subscription ($subscription_id, $reason = 'payment_failure') {
    return $self->update_subscription($subscription_id, {
        pause_collection => {
            behavior => 'mark_uncollectible',
        },
    });
}

method resume_subscription ($subscription_id) {
    return $self->update_subscription($subscription_id, {
        pause_collection => undef,
    });
}

method cancel_subscription_with_reason ($subscription_id, $reason = 'requested_by_customer') {
    return $self->cancel_subscription($subscription_id, {
        cancellation_details => {
            comment => $reason,
        },
    });
}

# Payment Intent Creation for Individual Installments
method create_installment_payment_intent ($args) {
    my $customer_id = $args->{customer_id} || die "customer_id required";
    my $payment_method_id = $args->{payment_method_id} || die "payment_method_id required";
    my $amount_cents = $args->{amount_cents} || die "amount_cents required";
    my $description = $args->{description} || 'Installment Payment';
    my $metadata = $args->{metadata} || {};

    return $self->create_payment_intent({
        amount => $amount_cents,
        currency => 'usd',
        customer => $customer_id,
        payment_method => $payment_method_id,
        confirm => 1, # Immediately attempt payment
        description => $description,
        metadata => $metadata,
    });
}

# Error Handling Helpers
method is_card_error ($error) {
    return $stripe_service->is_card_error($error);
}

method is_rate_limit_error ($error) {
    return $stripe_service->is_rate_limit_error($error);
}

method is_authentication_error ($error) {
    return $stripe_service->is_authentication_error($error);
}

method is_api_error ($error) {
    return $stripe_service->is_api_error($error);
}

}

1;