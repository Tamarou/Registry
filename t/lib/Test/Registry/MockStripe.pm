package Test::Registry::MockStripe;
# ABOUTME: Mock Stripe service for testing payment workflows
# ABOUTME: Provides simulated Stripe API responses without requiring real API calls

use 5.40.2;
use warnings;
use experimental 'signatures', 'try', 'builtin';

use Object::Pad;
class Test::Registry::MockStripe :isa(Registry::Service::Stripe) {

use Mojo::Promise;
use Mojo::JSON qw(encode_json decode_json);

field $_test_mode :param = 1;
field $_simulate_failure :param = 0;
field $_payment_intents = {};
field $_customers = {};
field $_payment_methods = {};
field $_subscriptions = {};
field $_refunds = {};

# Override the _request_async method to simulate Stripe API responses
method _request_async($method, $endpoint, $data = {}) {
    my $promise = Mojo::Promise->new;

    # Simulate async operation
    Mojo::IOLoop->timer(0 => sub {
        if ($_simulate_failure) {
            $promise->reject("Simulated Stripe API failure");
            return;
        }

        my $response;

        # Route to appropriate mock handler based on endpoint
        if ($endpoint eq 'payment_intents') {
            $response = $self->_mock_create_payment_intent($data);
        } elsif ($endpoint =~ m{^payment_intents/([^/]+)$}) {
            my $intent_id = $1;
            $response = $self->_mock_retrieve_payment_intent($intent_id);
        } elsif ($endpoint =~ m{^payment_intents/([^/]+)/confirm$}) {
            my $intent_id = $1;
            $response = $self->_mock_confirm_payment_intent($intent_id, $data);
        } elsif ($endpoint =~ m{^payment_intents/([^/]+)/cancel$}) {
            my $intent_id = $1;
            $response = $self->_mock_cancel_payment_intent($intent_id);
        } elsif ($endpoint eq 'customers') {
            $response = $self->_mock_create_customer($data);
        } elsif ($endpoint =~ m{^customers/([^/]+)$}) {
            my $customer_id = $1;
            if ($method eq 'GET') {
                $response = $self->_mock_retrieve_customer($customer_id);
            } else {
                $response = $self->_mock_update_customer($customer_id, $data);
            }
        } elsif ($endpoint eq 'subscriptions') {
            $response = $self->_mock_create_subscription($data);
        } elsif ($endpoint =~ m{^subscriptions/([^/]+)$}) {
            my $sub_id = $1;
            if ($method eq 'GET') {
                $response = $self->_mock_retrieve_subscription($sub_id);
            } elsif ($method eq 'DELETE') {
                $response = $self->_mock_cancel_subscription($sub_id, $data);
            } else {
                $response = $self->_mock_update_subscription($sub_id, $data);
            }
        } elsif ($endpoint eq 'refunds') {
            $response = $self->_mock_create_refund($data);
        } elsif ($endpoint =~ m{^refunds/([^/]+)$}) {
            my $refund_id = $1;
            $response = $self->_mock_retrieve_refund($refund_id);
        } else {
            # Default mock response
            $response = {
                id => "${endpoint}_test_" . time(),
                object => 'mock_object',
                created => time(),
            };
        }

        $promise->resolve($response);
    });

    return $promise;
}

method _mock_create_payment_intent($data) {
    my $intent_id = 'pi_test_' . time() . '_' . int(rand(10000));

    my $intent = {
        id => $intent_id,
        object => 'payment_intent',
        amount => $data->{amount} // 10000,
        currency => $data->{currency} // 'usd',
        status => 'requires_payment_method',
        client_secret => "${intent_id}_secret_" . time(),
        created => time(),
        metadata => $data->{metadata} // {},
        description => $data->{description} // '',
        receipt_email => $data->{receipt_email} // undef,
    };

    $_payment_intents->{$intent_id} = $intent;
    return $intent;
}

method _mock_retrieve_payment_intent($intent_id) {
    # Special handling for test success intent
    if ($intent_id eq 'pi_test_success') {
        return {
            id => $intent_id,
            object => 'payment_intent',
            amount => 15000,  # $150 in cents
            currency => 'usd',
            status => 'succeeded',
            payment_method => 'pm_test_visa',
            created => time(),
        };
    }

    # Return stored intent or create a succeeded one
    return $_payment_intents->{$intent_id} // {
        id => $intent_id,
        object => 'payment_intent',
        amount => 10000,
        currency => 'usd',
        status => 'succeeded',
        payment_method => 'pm_test_visa',
        created => time(),
    };
}

method _mock_confirm_payment_intent($intent_id, $data) {
    my $intent = $_payment_intents->{$intent_id} // $self->_mock_retrieve_payment_intent($intent_id);

    $intent->{status} = 'succeeded';
    $intent->{payment_method} = $data->{payment_method} // 'pm_test_visa';

    $_payment_intents->{$intent_id} = $intent;
    return $intent;
}

method _mock_cancel_payment_intent($intent_id) {
    my $intent = $_payment_intents->{$intent_id} // $self->_mock_retrieve_payment_intent($intent_id);

    $intent->{status} = 'canceled';
    $intent->{canceled_at} = time();

    $_payment_intents->{$intent_id} = $intent;
    return $intent;
}

method _mock_create_customer($data) {
    my $customer_id = 'cus_test_' . time() . '_' . int(rand(10000));

    my $customer = {
        id => $customer_id,
        object => 'customer',
        email => $data->{email} // undef,
        name => $data->{name} // undef,
        metadata => $data->{metadata} // {},
        created => time(),
    };

    $_customers->{$customer_id} = $customer;
    return $customer;
}

method _mock_retrieve_customer($customer_id) {
    return $_customers->{$customer_id} // {
        id => $customer_id,
        object => 'customer',
        email => 'test@example.com',
        created => time(),
    };
}

method _mock_update_customer($customer_id, $data) {
    my $customer = $_customers->{$customer_id} // $self->_mock_retrieve_customer($customer_id);

    for my $key (keys %$data) {
        $customer->{$key} = $data->{$key};
    }

    $_customers->{$customer_id} = $customer;
    return $customer;
}

method _mock_create_subscription($data) {
    my $sub_id = 'sub_test_' . time() . '_' . int(rand(10000));

    my $subscription = {
        id => $sub_id,
        object => 'subscription',
        customer => $data->{customer},
        status => 'active',
        current_period_start => time(),
        current_period_end => time() + 2592000,  # 30 days
        metadata => $data->{metadata} // {},
        created => time(),
    };

    $_subscriptions->{$sub_id} = $subscription;
    return $subscription;
}

method _mock_retrieve_subscription($sub_id) {
    return $_subscriptions->{$sub_id} // {
        id => $sub_id,
        object => 'subscription',
        status => 'active',
        created => time(),
    };
}

method _mock_update_subscription($sub_id, $data) {
    my $subscription = $_subscriptions->{$sub_id} // $self->_mock_retrieve_subscription($sub_id);

    for my $key (keys %$data) {
        $subscription->{$key} = $data->{$key};
    }

    $_subscriptions->{$sub_id} = $subscription;
    return $subscription;
}

method _mock_cancel_subscription($sub_id, $data) {
    my $subscription = $_subscriptions->{$sub_id} // $self->_mock_retrieve_subscription($sub_id);

    $subscription->{status} = 'canceled';
    $subscription->{canceled_at} = time();
    $subscription->{cancellation_details} = $data->{cancellation_details} // {};

    $_subscriptions->{$sub_id} = $subscription;
    return $subscription;
}

method _mock_create_refund($data) {
    my $refund_id = 'r_test_' . time() . '_' . int(rand(10000));

    my $refund = {
        id => $refund_id,
        object => 'refund',
        amount => $data->{amount} // 10000,
        payment_intent => $data->{payment_intent},
        reason => $data->{reason} // 'requested_by_customer',
        status => 'succeeded',
        created => time(),
    };

    $_refunds->{$refund_id} = $refund;
    return $refund;
}

method _mock_retrieve_refund($refund_id) {
    return $_refunds->{$refund_id} // {
        id => $refund_id,
        object => 'refund',
        amount => 10000,
        status => 'succeeded',
        created => time(),
    };
}

# Helper method to set test mode behavior
method set_simulate_failure($should_fail) {
    $_simulate_failure = $should_fail;
}

# Helper method to reset all mock data
method reset_mock_data() {
    $_payment_intents = {};
    $_customers = {};
    $_payment_methods = {};
    $_subscriptions = {};
    $_refunds = {};
}

}

1;