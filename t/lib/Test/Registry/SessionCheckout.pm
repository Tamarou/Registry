# ABOUTME: Test helper paying for a held session cart as Stripe settles it: the charge started with its intent stored,
# ABOUTME: a signed Connect payment_intent.succeeded posted, and the queued run drivers performed. No Stripe call is made.
use 5.42.0;
use warnings;

package Test::Registry::SessionCheckout;

use Exporter 'import';
our @EXPORT_OK = qw( started_charge post_succeeded drive );

use Test::Registry::StripeWebhook;
use Registry::DAO::Payment;

# started_charge($db, $run, $pay): the cart's payment row, as the payment step
# $pay starts it, with the intent Stripe would answer recorded on it.
sub started_charge ( $db, $run, $pay ) {
    my $owed = $pay->owed_payment( $db, $run );
    die "payment refused: $owed->{errors}[0]\n" if $owed->{errors};
    my $payment = $owed->{payment};
    $payment->_record_intent( $db, { id => 'pi_cart_' . $payment->id, client_secret => 'x_secret' } );
    return Registry::DAO::Payment->find( $db, { id => $payment->id } );
}

# post_succeeded($t, $payment, $account, %over): payment_intent.succeeded on
# the Connect endpoint for $payment, as Stripe sends it from the seller's
# $account; %over replaces parts of the intent (amount, id).
sub post_succeeded ( $t, $payment, $account, %over ) {
    return Test::Registry::StripeWebhook::post_connect( $t, {
        type    => 'payment_intent.succeeded',
        account => $account,
        data    => { object => {
            id       => $payment->stripe_payment_intent_id,
            amount   => $payment->amount_cents,
            metadata => { payment_id => $payment->id, tenant_slug => $payment->metadata->{tenant_slug} },
            %over,
        } },
    } );
}

# drive($minion): performs the queued run drivers, as Minion's worker would.
sub drive ($minion) {
    my $jobs = $minion->jobs( { tasks => ['continue_workflow_run'], states => ['inactive'] } );
    while ( my $job = $jobs->next ) { $minion->perform_jobs( { id => $job->{id} } ) }
}

1;
