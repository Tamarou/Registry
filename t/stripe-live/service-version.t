# ABOUTME: Gated real-Stripe regression: the production Stripe client's default
# ABOUTME: API version must be one Stripe actually accepts on every request.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::StripeConnect ();
use Registry::Service::Stripe;

# Gated: runs only with a real sk_test_ key. The bug this pins is invisible to
# the mock suite -- mocks intercept the transport and never send the
# Stripe-Version header to Stripe, which is the only party that validates it.
plan skip_all => 'STRIPE_SECRET_KEY (sk_test_) not set'
    unless Test::Registry::StripeConnect::available();

# The PRODUCTION client, constructed exactly as Payment.pm does: api_key only,
# so the default api_version is exercised and sent as the Stripe-Version
# header on the request below.
my $stripe = Registry::Service::Stripe->new(api_key => $ENV{STRIPE_SECRET_KEY});

# One real API call. If the default version is invalid, Stripe rejects the
# request and the sync wrapper croaks with "Invalid Stripe API version",
# failing this test. A valid version returns the created customer.
my $customer = eval {
    $stripe->create_customer({
        email       => 'version-check@tamarou.com',
        description => 'Registry Stripe-Version regression check',
        'metadata[purpose]' => 'registry-test-suite',
    });
};
my $err = $@;

ok !$err, 'production Stripe client made a real call without error'
    or diag "Stripe call failed: $err";
is ref $customer, 'HASH', 'got a decoded customer object back';
like $customer->{id} // '', qr/^cus_/, 'response carries a customer id';

# Best-effort cleanup: delete the probe customer (test-mode residue is harmless
# either way, so ignore any failure).
if ($customer && $customer->{id}) {
    eval { $stripe->delete_customer_async($customer->{id})->wait };
}

done_testing;
