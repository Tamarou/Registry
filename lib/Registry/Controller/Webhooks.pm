use 5.34.0;
use experimental 'signatures';
use Object::Pad;

class Registry::Controller::Webhooks :isa(Registry::Controller) {
    use JSON;
    use Digest::SHA qw(hmac_sha256_hex);

    method stripe($c) {
        # Verify webhook signature
        my $payload = $c->req->body;
        my $sig_header = $c->req->headers->header('stripe-signature');
        my $endpoint_secret = $ENV{STRIPE_WEBHOOK_SECRET};
        
        if ($endpoint_secret && !$self->_verify_stripe_signature($payload, $sig_header, $endpoint_secret)) {
            $c->render(status => 400, text => 'Invalid signature');
            return;
        }
        
        # Parse webhook event
        my $event;
        eval {
            $event = decode_json($payload);
        };
        
        if ($@) {
            $c->render(status => 400, text => 'Invalid JSON');
            return;
        }
        
        # Process the event
        my $subscription_dao = Registry::DAO::Subscription->new(db => $c->pg);
        
        eval {
            $subscription_dao->process_webhook_event(
                $event->{id},
                $event->{type},
                $event->{data}
            );
        };
        
        if ($@) {
            $c->app->log->error("Webhook processing failed: $@");
            $c->render(status => 500, text => 'Webhook processing failed');
            return;
        }
        
        $c->render(status => 200, text => 'OK');
    }

    method _verify_stripe_signature($payload, $sig_header, $endpoint_secret) {
        return 1 unless $endpoint_secret; # Skip verification if no secret configured
        
        my @sig_elements = split /,/, $sig_header;
        my %sigs;
        
        for my $element (@sig_elements) {
            my ($key, $value) = split /=/, $element, 2;
            if ($key eq 'v1') {
                $sigs{v1} = $value;
            } elsif ($key eq 't') {
                $sigs{t} = $value;
            }
        }
        
        return 0 unless $sigs{v1} && $sigs{t};
        
        # Check timestamp (within 5 minutes)
        my $timestamp = $sigs{t};
        my $current_time = time();
        return 0 if abs($current_time - $timestamp) > 300;
        
        # Verify signature
        my $signed_payload = $timestamp . '.' . $payload;
        my $expected_sig = hmac_sha256_hex($signed_payload, $endpoint_secret);
        
        return $expected_sig eq $sigs{v1};
    }
}