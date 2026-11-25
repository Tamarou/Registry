# ABOUTME: entitlement-stripe-move step: applies a refund Stripe reported to the entitlements its payment bought.
# ABOUTME: Follows Stripe, never the offer's refund policy: a full refund ends one, a partial one is recorded.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::ApplyStripeRefund :isa(Registry::DAO::WorkflowStep) {
    use List::Util qw( min sum0 );
    use Registry::DAO::Entitlement;

    # The refunds stored Connect event $event reports, each naming its
    # payment_intent: a refund.* event carries one; charge.refunded lists the
    # charge's when Stripe includes them.
    sub refunds ( $class, $event ) {
        my $object = ref $event eq 'HASH' && ref $event->{data} eq 'HASH' ? $event->{data}{object} : undef;
        return () unless ref $object eq 'HASH';
        my $type = $event->{type} // '';
        my @refunds = $type =~ /\A(?:charge\.)?refund\.\w+\z/ ? ($object)
            : $type eq 'charge.refunded' && ref $object->{refunds} eq 'HASH' ? @{ $object->{refunds}{data} // [] }
            : ();
        return grep { defined $_->{id} && !ref $_->{id} && defined $_->{payment_intent} && !ref $_->{payment_intent} }
            map { { payment_intent => $object->{payment_intent}, %$_ } } grep { ref eq 'HASH' } @refunds;
    }

    # Applies the stored event the run was created for (run data
    # stripe_event_id) once: it is locked, read only for this schema's tenant,
    # and marked applied in the same transaction as what it changes, so a
    # second run for it waits and then finds nothing to do.
    method process ( $db, $form_data, $run = undef ) {
        $db = $db->db if $db isa Registry::DAO;
        my $event_id = $run ? $run->data->{stripe_event_id} : undef;
        return { stay => 1, errors => ['This run names no stored Stripe event'] }
            unless defined $event_id && !ref $event_id;

        my $tx     = $db->dbh->{AutoCommit} ? $db->begin : undef;
        my $stored = $db->query( q{
            SELECT e.payload FROM registry.webhook_events e JOIN registry.tenants t ON t.id = e.tenant_id
             WHERE e.stripe_event_id = ? AND t.slug = current_schema() AND e.processed_at IS NULL
               FOR UPDATE OF e
        }, $event_id )->expand->hash;
        if ($stored) {
            $self->_apply( $db, $_ ) for __PACKAGE__->refunds( $stored->{payload} );
            $db->query( 'UPDATE registry.webhook_events SET processed_at = now() WHERE stripe_event_id = ?',
                $event_id );
        }
        $tx->commit if $tx;
        return {};
    }

    # A succeeded refund of a payment Registry made here, matched by the intent
    # stored on that payment. It is shared among the payment's entitlements in
    # proportion to what each has not yet had refunded, rounding down, the
    # leftover cents one each to the largest remainders (ties: the one created
    # first). One whose refunds reach its share ends as refunded.
    method _apply ( $db, $refund ) {
        return unless ( $refund->{status} // '' ) eq 'succeeded';
        my ($amount) = grep { /\A[1-9][0-9]{0,11}\z/ } $refund->{amount} // '';
        return unless $amount;
        my $payment = $db->query( 'SELECT id FROM payments WHERE stripe_payment_intent_id = ? FOR UPDATE',
            $refund->{payment_intent} )->hash or return;

        my @entitlements = sort { $a->created_at cmp $b->created_at || $a->id cmp $b->id }
            grep { $_->payment_share_cents } Registry::DAO::Entitlement->created_by_payment( $db, $payment->{id} );
        return unless @entitlements;
        # Another event reporting the same refund adds nothing.
        return if $db->query( 'SELECT 1 FROM entitlement_refunds WHERE stripe_refund_id = ? AND entitlement_id = ANY (?)',
            $refund->{id}, [ map { $_->id } @entitlements ] )->rows;

        my @left  = map { my $l = $_->payment_share_cents - $_->refunded_cents($db); $l > 0 ? $l : 0 } @entitlements;
        my $total = sum0(@left) or return;
        $amount = min( $amount, $total );
        my @part = map { int( $amount * $_ / $total ) } @left;
        my $rest = $amount - sum0(@part);
        $part[$_]++ for ( sort { ( $amount * $left[$b] ) % $total <=> ( $amount * $left[$a] ) % $total || $a <=> $b }
            0 .. $#left )[ 0 .. $rest - 1 ];

        for my $i ( 0 .. $#entitlements ) {
            next unless $part[$i];
            my $e = $entitlements[$i];
            $e->record_refund( $db, { amount_cents => $part[$i], stripe_refund_id => $refund->{id} } );
            $e->end( $db, 'refunded', $refund->{id} ) if $part[$i] == $left[$i] && $e->state eq 'active';
        }
    }
}

1;
