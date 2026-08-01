# ABOUTME: Resolves a workflow step result that may be a promise, for tests
# ABOUTME: that drive steps directly instead of through a running event loop.
use 5.42.0;

package Test::Registry::Async;

use Exporter 'import';
use Mojo::Promise ();

our @EXPORT_OK = qw( settle );

# Steps that talk to Stripe return a Mojo::Promise; the rest return a hashref.
# Under `prove` there is no running IOLoop, so ->wait genuinely blocks here and
# this is safe -- which is precisely why it would NOT be safe in the web path,
# and why the step is async in the first place. Tests that need to prove the
# running-loop behaviour must start a loop themselves; see
# t/dao/payment-step-async.t.
sub settle ($result) {
    return $result unless ref $result && $result isa Mojo::Promise;

    my ( $value, $error, $settled );
    $result->then(
        sub { $value = shift; $settled = 1 },
        sub { $error = shift // 'unknown promise rejection'; $settled = 1 },
    )->wait;

    die "step promise did not settle - is an event loop already running?\n"
        unless $settled;
    die $error if defined $error;

    return $value;
}

1;
