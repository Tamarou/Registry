use 5.42.0;
# ABOUTME: Test helper for confirming Stripe PaymentIntents against the real Stripe test API.
# ABOUTME: Confirms and polls on a connected account (Stripe-Account) for the gated direct-charge suite.
use Test::Registry::StripeConnect ();

package Test::Registry::StripeConfirm {

    my $BASE = 'https://api.stripe.com/v1';

    # Delegate gating and transport to StripeConnect to avoid duplication.
    sub _key { Test::Registry::StripeConnect::_key() }
    sub _ua  { Test::Registry::StripeConnect::_ua()  }

    # POST and return raw decoded JSON without auto-dying on Stripe API errors.
    # Callers that need error inspection (confirm) must check $data->{error} themselves.
    # Dies only when the HTTP layer returns no JSON at all.
    # $account, when given, names the connected account the call acts on: a
    # direct charge and everything about it lives there, not on the platform.
    sub _headers {
        my ($account) = @_;
        return {
            Authorization => 'Bearer ' . _key(),
            ( defined $account ? ( 'Stripe-Account' => $account ) : () ),
        };
    }

    sub _post_raw {
        my ($path, $params, $account) = @_;
        my $tx  = _ua()->post(
            "$BASE$path",
            _headers($account),
            form => $params,
        );
        my $data = $tx->res->json
            or die "Stripe POST $path: no JSON body (HTTP " . $tx->res->code . ")\n";
        return $data;
    }

    # POST and die on any Stripe API error, same discipline as StripeConnect::_post.
    sub _post {
        my ($path, $params, $account) = @_;
        my $data = _post_raw($path, $params, $account);
        die "Stripe POST $path error: $data->{error}{message}\n" if $data->{error};
        return $data;
    }

    sub _get {
        my ($path, $account) = @_;
        my $tx  = _ua()->get(
            "$BASE$path",
            _headers($account),
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
    # %params are passed directly as form fields, except stripe_account, which
    # names the connected account to create it on, e.g.:
    #   create_payment_intent(amount => 500, currency => 'usd', 'payment_method_types[]' => 'card')
    sub create_payment_intent {
        my (%params) = @_;
        my $account = delete $params{stripe_account};
        return _post('/payment_intents', \%params, $account);
    }

    # Confirm a PaymentIntent server-side with the given payment method.
    # Returns the decoded confirmed intent on success.
    # Dies with Stripe error message + type/code/decline_code on any Stripe error
    # so callers (e.g. C3's I3 decline test) can catch and inspect it via eval/$@.
    #
    # A return_url is always sent: production intents are created with
    # automatic_payment_methods enabled (the browser uses the Payment Element +
    # stripe.confirmPayment with a return_url), so Stripe requires a return_url
    # when confirming server-side even though pm_card_visa never redirects.
    #
    # $account is the connected account the intent was created on; a direct
    # charge's intent is not found on the platform account without it.
    sub confirm {
        my ($pi_id, $pm, $account) = @_;
        $pm //= 'pm_card_visa';
        my $data = _post_raw(
            "/payment_intents/$pi_id/confirm",
            {
                payment_method => $pm,
                return_url      => 'https://registry.test/stripe-return',
            },
            $account,
        );
        if ($data->{error}) {
            my $e = $data->{error};
            # Include all three fields so callers can match on type, code, or
            # decline_code; some error types leave code/decline_code unset.
            die "Stripe confirm error: $e->{message} "
              . "(type=" . ( $e->{type}         // '' )
              . " code=" . ( $e->{code}         // '' )
              . " decline_code=" . ( $e->{decline_code} // '' ) . ")\n";
        }
        return $data;
    }

    # Retrieve the Charge created for a PaymentIntent by following latest_charge,
    # on $account when given. Returns the decoded charge object.
    sub charge_for {
        my ($pi_id, $account) = @_;
        my $intent    = _get("/payment_intents/$pi_id", $account);
        my $charge_id = $intent->{latest_charge}
            or die "PaymentIntent $pi_id has no latest_charge\n";
        return _get("/charges/$charge_id", $account);
    }

    # Like charge_for, but polls until the application fee is attached. On a
    # direct charge the application_fee object is created a few seconds after
    # the charge succeeds (Stripe eventual consistency), so the charge's
    # application_fee id is briefly empty; application_fee_amount is present
    # immediately. There is no transfer to wait for: the money is already on
    # the connected account.
    sub charge_for_settled {
        my ($pi_id, $account, %opt) = @_;
        my $timeout  = $opt{timeout} // 30;
        my $deadline = time() + $timeout;
        while (1) {
            my $charge = charge_for($pi_id, $account);
            return $charge if $charge->{application_fee};
            die "charge for $pi_id did not attach application_fee "
              . "within ${timeout}s\n"
                if time() >= $deadline;
            sleep 2;
        }
    }
}

1;
