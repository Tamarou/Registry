# ABOUTME: Minion job that refunds, in full, a superseded intent a stale tab paid (ruling 7a), or a wrong-amount charge (7b).
# ABOUTME: Retried on its attempts; tells the parent of a duplicate when it is made, and staff when the last attempt fails.
use 5.42.0;
use Object::Pad;

class Registry::Job::SupersededRefund {
    use Registry::DAO::Notification;
    use Registry::DAO::Payment;
    use Registry::Service::Stripe;

    sub register ($class, $app) {
        $app->minion->add_task( superseded_refund => sub ($job, @args) {
            $class->new->run( $job, @args );
        } );
    }

    # Why Registry refunds a charge on its own. A superseded intent is a
    # duplicate, and its payer is told here once it is refunded; a charge for
    # the wrong amount was refused by the webhook, which told its payer.
    my %KIND = (
        superseded   => { reason => 'duplicate', tell_parent => 1,
                          what => 'a replaced attempt a stale tab paid' },
        wrong_amount => { what => 'a charge for other than its quoted amount' },
    );

    # $intent was charged $cents on the seller account $account, for payment
    # $payment_id in tenant schema $slug: after a newer intent replaced it, or
    # ($kind wrong_amount) for other than the payment's amount.
    method run ( $job, $intent, $account, $cents, $payment_id, $slug, $kind = 'superseded' ) {
        my $db   = $job->app->dao($slug)->db;
        my $what = $KIND{$kind} or return $job->fail("unknown refund kind '$kind' for intent $intent");

        my $refund;
        try {
            $refund = Registry::Service::Stripe->from_env->for_account($account)->create_refund({
                payment_intent   => $intent,
                ( $what->{reason} ? ( reason => $what->{reason} ) : () ),
                _idempotency_key => "refund:$kind:$intent",
            });
        }
        catch ($err) {
            # An invalid_request_error is Stripe refusing the request itself, and
            # it refuses it again on every retry -- bar the codes Stripe uses for load
            # and contention, which do clear.
            if ( $err =~ /\AStripe invalid_request_error:/
                 && $err !~ /\((?:rate_limit|lock_timeout|idempotency_key_in_use)\)/ ) {
                if ( $err =~ /\(charge_already_refunded\)/ ) {
                    $job->app->log->info("$kind intent $intent was already refunded");
                    $self->_tell_parent( $db, $cents, $payment_id ) if $what->{tell_parent};
                    return $job->finish("$kind intent $intent was already refunded");
                }
                $self->_tell_staff( $job, $db, $intent, $cents, $payment_id, $err, $what );
                return $job->finish("refund of $kind intent $intent refused, not retried: $err");
            }

            # Failing retries the job while it has attempts left; only the last
            # one is worth a person's time. Minion counts attempts down on each
            # retry, so the last run is the one with one left.
            $self->_tell_staff( $job, $db, $intent, $cents, $payment_id, $err, $what )
                if $job->info->{attempts} <= 1;
            return $job->fail("refund of $kind intent $intent failed: $err");
        }

        $job->app->log->info("$kind intent $intent refunded ($refund->{id})");
        $self->_tell_parent( $db, $cents, $payment_id ) if $what->{tell_parent};
        return $job->finish("$kind intent $intent refunded as $refund->{id}");
    }

    method _tell_staff ( $job, $db, $intent, $cents, $payment_id, $err, $what ) {
        my $sum = _sum($cents);
        Registry::DAO::Notification->alert_admins( $db,
            'Refund failed: refund it by hand',
            "Registry could not refund $sum charged on Stripe intent $intent for "
          . "payment $payment_id, $what->{what}. "
          . 'Refund it by hand in Stripe.',
            { payment_id => $payment_id, payment_intent_id => $intent } );
        # Stripe's text is not ours: escaped, so it cannot forge a log line.
        my $why = "$err" =~ s/\s+\z//r =~ s/([^\x20-\x7e])/sprintf '\\x{%x}', ord $1/ger;
        $job->app->log->error( "refund of intent $intent ($sum, payment "
              . "$payment_id, $what->{what}) failed; refund it by hand: $why" );
    }

    # Whoever the payment row says paid, as ruling 7a asks. A row that has gone
    # leaves nobody to tell; the refund stands.
    method _tell_parent ( $db, $cents, $payment_id ) {
        my $payment = Registry::DAO::Payment->find( $db, { id => $payment_id } ) or return;
        Registry::DAO::Notification->create( $db, {
            user_id  => $payment->user_id,
            type     => 'general',
            channel  => 'email',
            subject  => 'Your duplicate payment was refunded',
            message  => 'An earlier attempt at your payment went through after it had '
                      . 'been replaced, so you were charged twice. We have refunded '
                      . _sum($cents) . ' in full; it can take 5-10 business days to '
                      . 'show on your statement. Nothing else changes.',
            metadata => { payment_id => $payment_id },
        } );
    }

    sub _sum ($cents) { defined $cents ? sprintf( '$%.2f', $cents / 100 ) : 'the full charge' }
}
