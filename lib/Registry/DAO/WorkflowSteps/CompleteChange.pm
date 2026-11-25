# ABOUTME: entitlement-change step: once the change fee is paid, moves the entitlement onto the held target.
# ABOUTME: Reads only the run's server-owned change_hold and owed_payment_id, never the form; moving twice moves once.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::CompleteChange :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Entitlement;
    use Registry::DAO::Notification;
    use Registry::DAO::Payment;
    use Registry::DAO::WorkflowSteps::ChooseChangeTarget;
    use Registry::PriceOps::Hold;

    my $UUID = qr/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i;

    method process ( $db, $form_data, $run = undef ) {
        $db = $db->db if $db isa Registry::DAO;
        my $tx = $db->dbh->{AutoCommit} ? $db->begin : undef;
        # The person's return and the driver may both arrive: the second waits
        # here and finds the hold already converted.
        my $data = $db->query( 'SELECT data FROM workflow_runs WHERE id = ? FOR UPDATE', $run->id )
            ->expand->hash->{data} // {};
        my $change  = $data->{change_hold};
        my $hold_id = ref $change eq 'HASH' ? $change->{hold_id} : undef;
        my $hold    = defined $hold_id && !ref $hold_id && $hold_id =~ $UUID
            && Registry::PriceOps::Hold->find( $db, { id => $hold_id, workflow_run_id => $run->id }, 'id' );
        return $self->_stay('Choose an occurrence to change to') unless $hold;
        return {} if $hold->state eq 'converted';

        # Whoever completes it must be allowed to change this booking, as at
        # choose, hold and pay; the controller puts the requester on the run.
        my $entitlement = Registry::DAO::Entitlement->find( $db, { id => $change->{entitlement_id} } );
        my $refusal     = $entitlement
            && Registry::DAO::WorkflowSteps::ChooseChangeTarget->stranger( $entitlement, $data->{user} );
        return $self->_stay($refusal) if $refusal;

        my $payment = $self->_paid( $db, $run, $data );
        return $self->_stay('The change fee has not been paid yet') unless $payment;

        # Locked before any hold, as convert locks it: a move or end waits.
        # One that ended meanwhile is not moved; its paid fee is kept.
        my $current = Registry::DAO::Entitlement->in_effect_sql( 'e', 'tstzrange(now(), NULL)' );
        unless ( $db->query( "SELECT $current FROM entitlements e WHERE e.id = ? FOR UPDATE",
                $change->{entitlement_id} )->array->[0] ) {
            return $self->_needs_admin( $db, $tx, $run, $data, $payment, 'the booking ended before it was moved' )
                if ref $payment;
            return $self->_stay('This booking has ended and cannot be changed');
        }

        my $live = Registry::PriceOps::Hold->live_sql('holds');
        unless ( $db->query( "SELECT $live FROM holds WHERE id = ?", $hold->id )->array->[0] ) {
            # Paid after the hold lapsed. Registry never refunds a change fee,
            # so the seats are taken again, under the target's lock, if free.
            $hold->release($db);
            my $again = eval {
                Registry::PriceOps::Hold->place( $db, {
                    resource_id     => $hold->resource_id,
                    units           => $hold->units,
                    workflow_run_id => $run->id,
                    expires_at      => \"clock_timestamp() + interval '1 minute'",    # converted below
                } );
            };
            unless ($again) {
                die $@ unless $@ =~ /units free/;
                return $self->_needs_admin( $db, $tx, $run, $data, $payment, 'the target occurrence is now full' )
                    if ref $payment;
                return $self->_stay('That occurrence no longer has room');
            }
            $hold = $again;
            $run->update_data( $db, { change_hold => { %$change, hold_id => $hold->id } } );
        }

        # Read again now it is locked, so convert sees its current state.
        $entitlement = Registry::DAO::Entitlement->find( $db, { id => $change->{entitlement_id} } );
        $hold->convert( $db, $entitlement );
        $tx->commit if $tx;
        return {};
    }

    # Paid: 1 for a zero fee, or this run's own payment when it completed for
    # exactly the stamped fee under the stamped version; otherwise 0.
    method _paid ( $db, $run, $data ) {
        my $change = $data->{change_hold};
        return 1 unless $change->{fee_cents};
        my $id = $data->{owed_payment_id};
        return 0 unless defined $id && !ref $id && $id =~ $UUID;
        my $payment = Registry::DAO::Payment->find( $db, { id => $id } ) or return 0;
        return $payment->status eq 'completed'
            && ( $payment->metadata->{workflow_run_id} // '' ) eq $run->id
            && $payment->amount_cents == $change->{fee_cents}
            && ( $payment->offer_version_id // '' ) eq ( $change->{offer_version_id} // "\0" )
            ? $payment : 0;
    }

    # A paid change that cannot be made ($why): the entitlement stays where it
    # was and the fee is kept. Recorded on the run and put before the admins.
    # The person is told so; the driver is asked to retry (a seat may free
    # up), and its last attempt halts the run.
    method _needs_admin ( $db, $tx, $run, $data, $payment, $why ) {
        unless ( $data->{change_needs_admin} ) {
            $run->update_data( $db, { change_needs_admin => {
                payment_id           => $payment->id,
                entitlement_id       => $data->{change_hold}{entitlement_id},
                target_occurrence_id => $data->{change_hold}{target_occurrence_id},
                reason               => $why,
            } } );
            Registry::DAO::Notification->alert_admins( $db,
                'A paid change could not be made: it needs an admin',
                sprintf( 'The change fee on payment %s was paid, but %s. The booking was not moved '
                    . 'and the fee was not refunded.', $payment->id, $why ),
                { workflow_run_id => $run->id, payment_id => $payment->id } );
        }
        $tx->commit if $tx;
        return {
            stay   => 1,
            errors => ["Your change fee is paid, but $why, so your booking has not moved. "
                . 'The studio has been told and will sort it out with you.'],
            retry  => sprintf( "change on run %s is paid but %s: it needs an admin\n", $run->id, $why ),
        };
    }

    method _stay ($why) { return { stay => 1, errors => [$why] } }
}

1;
