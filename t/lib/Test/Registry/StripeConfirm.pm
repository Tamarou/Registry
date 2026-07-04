use 5.42.0;
# ABOUTME: Test helper for confirming Stripe PaymentIntents against the real Stripe test API.
# ABOUTME: Provides confirm() and charge_for() for the gated real-Stripe test suite (Leg C3).
use Test::Registry::StripeConnect ();

package Test::Registry::StripeConfirm {

    my $BASE = 'https://api.stripe.com/v1';

    # Delegate gating and transport to StripeConnect to avoid duplication.
    sub _key { Test::Registry::StripeConnect::_key() }
    sub _ua  { Test::Registry::StripeConnect::_ua()  }

    # POST and return raw decoded JSON without auto-dying on Stripe API errors.
    # Callers that need error inspection (confirm) must check $data->{error} themselves.
    # Dies only when the HTTP layer returns no JSON at all.
    sub _post_raw {
        my ($path, $params) = @_;
        my $key = _key();
        my $tx  = _ua()->post(
            "$BASE$path",
            { Authorization => "Bearer $key" },
            form => $params,
        );
        my $data = $tx->res->json
            or die "Stripe POST $path: no JSON body (HTTP " . $tx->res->code . ")\n";
        return $data;
    }

    # POST and die on any Stripe API error, same discipline as StripeConnect::_post.
    sub _post {
        my ($path, $params) = @_;
        my $data = _post_raw($path, $params);
        die "Stripe POST $path error: $data->{error}{message}\n" if $data->{error};
        return $data;
    }

    sub _get {
        my ($path) = @_;
        my $key = _key();
        my $tx  = _ua()->get(
            "$BASE$path",
            { Authorization => "Bearer $key" },
        );
        my $data = $tx->res->json
            or die "Stripe GET $path: no JSON body (HTTP " . $tx->res->code . ")\n";
        die "Stripe GET $path error: $data->{error}{message}\n" if $data->{error};
        return $data;
    }

    # True only when the environment carries a valid sk_test_ key.
    # Callers should use Test::Registry::StripeConnect::available() directly;
    # this is a convenience alias so callers don't have to import both modules.
    sub available { Test::Registry::StripeConnect::available() }

    # Create a bare PaymentIntent against the Stripe test API.
    # %params are passed directly as form fields, e.g.:
    #   create_payment_intent(amount => 500, currency => 'usd', 'payment_method_types[]' => 'card')
    sub create_payment_intent {
        my (%params) = @_;
        return _post('/payment_intents', \%params);
    }

    # Confirm a PaymentIntent server-side with the given payment method.
    # Returns the decoded confirmed intent on success.
    # Dies with Stripe error message + type/code/decline_code on any Stripe error
    # so callers (e.g. C3's I3 decline test) can catch and inspect it via eval/$@.
    sub confirm {
        my ($pi_id, $pm) = @_;
        $pm //= 'pm_card_visa';
        my $data = _post_raw(
            "/payment_intents/$pi_id/confirm",
            { payment_method => $pm },
        );
        if ($data->{error}) {
            my $e = $data->{error};
            # Include all three fields so callers can match on type, code, or decline_code.
            die "Stripe confirm error: $e->{message} "
              . "(type=$e->{type} code=$e->{code} decline_code=$e->{decline_code})\n";
        }
        return $data;
    }

    # Retrieve the Charge created for a PaymentIntent by following latest_charge.
    # Returns the decoded charge object.
    sub charge_for {
        my ($pi_id) = @_;
        my $intent    = _get("/payment_intents/$pi_id");
        my $charge_id = $intent->{latest_charge}
            or die "PaymentIntent $pi_id has no latest_charge\n";
        return _get("/charges/$charge_id");
    }
}

1;
