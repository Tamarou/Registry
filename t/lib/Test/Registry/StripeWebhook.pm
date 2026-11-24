use 5.42.0;
# ABOUTME: Test helper for building, signing, and posting Stripe webhook events (platform and Connect).
# ABOUTME: Used by the gated real-Stripe suite (Leg C3), the helper self-test, and the Connect endpoint tests.

package Test::Registry::StripeWebhook {
    use Digest::SHA qw(hmac_sha256_hex);
    use Mojo::JSON qw(encode_json);

    # Per-process counter appended to generated event ids so repeated calls
    # within the same second and process still produce unique ids.
    # ponytail: process-global counter; fine for serial test files
    my $counter = 0;

    # Build, sign, and POST a payment_intent.succeeded event to the app under test.
    #
    # $t            - Test::Mojo (or Test::Registry::Mojo) object with a live app
    # $payment_id   - Registry payment row id; written into event metadata.payment_id
    # $tenant_slug  - tenant schema slug, or undef for registry-schema payments
    # $pi_id        - synthetic or real Stripe PaymentIntent id for the event object
    # %opts:
    #   event_id => '...'   override the auto-generated event id (for dedup replay tests)
    #
    # Signs with $ENV{STRIPE_WEBHOOK_SECRET} (exact shape from payment-intent-webhook.t).
    # Returns the Test::Mojo transaction so callers can chain ->status_is etc.
    sub post_succeeded {
        my ($t, $payment_id, $tenant_slug, $pi_id, %opts) = @_;

        my $event_id = exists $opts{event_id}
            ? $opts{event_id}
            : sprintf('evt_helper_%d_%d_%d', time(), $$, ++$counter);

        my $event = {
            id   => $event_id,
            type => 'payment_intent.succeeded',
            data => { object => {
                id       => $pi_id,
                metadata => {
                    payment_id => $payment_id,
                    (defined $tenant_slug ? (tenant_slug => $tenant_slug) : ()),
                },
            } },
        };

        my $payload   = encode_json($event);
        my $timestamp = time();
        my $sig       = hmac_sha256_hex("$timestamp.$payload", $ENV{STRIPE_WEBHOOK_SECRET});
        my $tx = $t->ua->post('/webhooks/stripe' => {
            'stripe-signature' => "t=$timestamp,v1=$sig",
            'Content-Type'     => 'application/json',
        } => $payload);
        return $t->tx($tx);
    }

    # Sign and POST a Connect event: one that happened on a connected account,
    # so Stripe sends it to the Connect endpoint with a top-level `account`.
    #
    # $t      - Test::Mojo object with a live app
    # $event  - event hashref; give it `account` (or leave it out to test that)
    # %opts:
    #   secret    => '...'   sign with this instead of STRIPE_CONNECT_WEBHOOK_SECRET
    #   path      => '...'   post here instead of /webhooks/stripe/connect
    #   timestamp => N       sign with this time instead of now
    #   body      => '...'   send this body instead of the one signed
    sub post_connect {
        my ($t, $event, %opts) = @_;

        $event->{id} //= sprintf('evt_connect_%d_%d_%d', time(), $$, ++$counter);

        my $payload   = encode_json($event);
        my $timestamp = $opts{timestamp} // time();
        my $secret    = $opts{secret} // $ENV{STRIPE_CONNECT_WEBHOOK_SECRET};
        my $sig       = hmac_sha256_hex("$timestamp.$payload", $secret);
        my $tx = $t->ua->post(($opts{path} // '/webhooks/stripe/connect') => {
            'stripe-signature' => "t=$timestamp,v1=$sig",
            'Content-Type'     => 'application/json',
        } => ($opts{body} // $payload));
        return $t->tx($tx);
    }
}

1;
