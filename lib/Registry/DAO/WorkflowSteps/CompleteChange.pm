# ABOUTME: entitlement-change step: once the change fee is paid, moves the entitlement onto the held target.
# ABOUTME: Reads only the run's server-owned change_hold and owed_payment_id, never the form; moving twice moves once.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::CompleteChange :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Entitlement;
    use Registry::DAO::Payment;
    use Registry::PriceOps::Hold;

    method process ( $db, $form_data, $run = undef ) {
        $db = $db->db if $db isa Registry::DAO;
        my $tx = $db->dbh->{AutoCommit} ? $db->begin : undef;
        # The person's return and the driver may both arrive: the second waits
        # here and finds the hold already converted.
        my $data = $db->query( 'SELECT data FROM workflow_runs WHERE id = ? FOR UPDATE', $run->id )
            ->expand->hash->{data} // {};
        my $change = $data->{change_hold};
        return $self->_stay('Choose an occurrence to change to') unless ref $change eq 'HASH';
        my $hold = Registry::PriceOps::Hold->find( $db, { id => $change->{hold_id}, workflow_run_id => $run->id }, 'id' )
            or return $self->_stay('Choose an occurrence to change to');
        return {} if $hold->state eq 'converted';

        return $self->_stay('The change fee has not been paid yet') unless $self->_paid( $db, $run, $data );

        my $entitlement = Registry::DAO::Entitlement->find( $db, { id => $change->{entitlement_id} } );
        $hold->convert( $db, $entitlement );
        $tx->commit if $tx;
        return {};
    }

    # The fee is paid when it is zero, or when this run's own payment
    # completed for exactly the stamped fee under the stamped version.
    method _paid ( $db, $run, $data ) {
        my $change = $data->{change_hold};
        return 1 unless $change->{fee_cents};
        my $id = $data->{owed_payment_id};
        return 0 unless defined $id && !ref $id && $id =~ /\A[0-9a-f-]{36}\z/i;
        my $payment = Registry::DAO::Payment->find( $db, { id => $id } ) or return 0;
        return $payment->status eq 'completed'
            && ( $payment->metadata->{workflow_run_id} // '' ) eq $run->id
            && $payment->amount_cents == $change->{fee_cents}
            && ( $payment->offer_version_id // '' ) eq $change->{offer_version_id};
    }

    method _stay ($why) { return { stay => 1, errors => [$why] } }
}

1;
