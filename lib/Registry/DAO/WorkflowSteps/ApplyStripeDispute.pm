# ABOUTME: entitlement-stripe-move step: a dispute Stripe reports lost ends the entitlements its payment bought.
# ABOUTME: Follows Stripe, never the offer's policies; opened, won or otherwise closed disputes change nothing.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::ApplyStripeDispute :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Entitlement;

    # The dispute stored Connect event $event reports, naming its
    # payment_intent; none when it is not a charge.dispute.* event.
    sub disputes ( $class, $event ) {
        my $object = ref $event eq 'HASH' && ref $event->{data} eq 'HASH' ? $event->{data}{object} : undef;
        return () unless ref $object eq 'HASH' && ( $event->{type} // '' ) =~ /\Acharge\.dispute\.\w+\z/;
        return () unless grep { defined && !ref } $object->@{qw( id payment_intent )};
        return $object;
    }

    # Applies the stored dispute event the run was created for (run data
    # stripe_event_id) once, as ApplyStripeRefund applies a refund: locked,
    # read only for this schema's tenant, and marked applied in the same
    # transaction as what it changes. Any other event is left to that step.
    method process ( $db, $form_data, $run = undef ) {
        $db = $db->db if $db isa Registry::DAO;
        my $event_id = $run ? $run->data->{stripe_event_id} : undef;
        return { stay => 1, errors => ['This run names no stored Stripe event'] }
            unless defined $event_id && !ref $event_id;

        my $tx     = $db->dbh->{AutoCommit} ? $db->begin : undef;
        my $stored = $db->query( q{
            SELECT e.payload FROM registry.webhook_events e JOIN registry.tenants t ON t.id = e.tenant_id
             WHERE e.stripe_event_id = ? AND t.slug = current_schema() AND e.processed_at IS NULL
               AND e.event_type LIKE 'charge.dispute.%'
               FOR UPDATE OF e
        }, $event_id )->expand->hash;
        if ($stored) {
            my $event = $stored->{payload};
            $self->_apply( $db, $_ ) for ( $event->{type} // '' ) eq 'charge.dispute.closed'
                ? __PACKAGE__->disputes($event) : ();
            $db->query( 'UPDATE registry.webhook_events SET processed_at = now() WHERE stripe_event_id = ?',
                $event_id );
        }
        $tx->commit if $tx;
        return {};
    }

    # A lost dispute of a payment Registry made here, matched by the intent
    # stored on that payment, ends each of its entitlements still active. One
    # already ended (refunded, expired) keeps how it ended.
    method _apply ( $db, $dispute ) {
        return unless ( $dispute->{status} // '' ) eq 'lost';
        my $payment = $db->query( 'SELECT id FROM payments WHERE stripe_payment_intent_id = ? FOR UPDATE',
            $dispute->{payment_intent} )->hash or return;
        $_->end( $db, 'dispute_lost', $dispute->{id} )
            for grep { $_->state eq 'active' } Registry::DAO::Entitlement->created_by_payment( $db, $payment->{id} );
    }
}

1;
