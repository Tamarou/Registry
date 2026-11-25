# ABOUTME: in-studio-booking step: once the booking is paid, turns the run's hold into the booker's entitlement, once.
# ABOUTME: Reads only server-owned run data; the entitlement is linked to its payment and stamped with the agreed terms at insert.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::CompleteBooking :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Entitlement;
    use Registry::DAO::Event;
    use Registry::DAO::OfferVersion;
    use Registry::DAO::WorkflowSteps::ChooseOfferAndUnits;
    use Registry::DAO::Payment;
    use Registry::DAO::Resource;
    use Registry::PriceOps::Hold;

    my $UUID = qr/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i;

    method process ( $db, $form_data, $run = undef ) {
        $db = $db->db if $db isa Registry::DAO;
        my $tx = $db->dbh->{AutoCommit} ? $db->begin : undef;
        # The person's return and the driver may both arrive: the second waits
        # here and finds the hold already converted.
        my $data = $db->query( 'SELECT data FROM workflow_runs WHERE id = ? FOR UPDATE', $run->id )
            ->expand->hash->{data} // {};
        my $booking = $data->{booking_hold};
        my $hold_id = ref $booking eq 'HASH' ? $booking->{hold_id} : undef;
        my $hold    = defined $hold_id && !ref $hold_id && $hold_id =~ $UUID
            && Registry::PriceOps::Hold->find( $db, { id => $hold_id, workflow_run_id => $run->id }, 'id' );
        return _stay('Choose the seats to book') unless $hold;
        return {} if $hold->state eq 'converted';

        my $payment = $self->_paid( $db, $run, $data );
        return _stay('This booking has not been paid for yet') unless $payment;
        # Stamped on the booking at insert (ADR 005, ruling 12); HoldSeats holds nothing without it.
        my $terms = $data->{agreed_terms_version};
        return _stay('Agree to the terms of service to book.') unless defined $terms && !ref $terms && length $terms;

        my $live = Registry::PriceOps::Hold->live_sql('holds');
        unless ( $db->query( "SELECT $live FROM holds WHERE id = ?", $hold->id )->array->[0] ) {
            # Paid after the hold lapsed: the seats are taken again, under the
            # occurrence's lock, if they still fit (ADR 005, ruling 7a).
            $hold->release($db);
            my $again = eval {
                Registry::PriceOps::Hold->place( $db, {
                    resource_id     => $hold->resource_id,
                    units           => $hold->units,
                    workflow_run_id => $run->id,
                    expires_at      => \"clock_timestamp() + interval '1 minute'",    # converted below
                } );
            };
            die $@ unless $again;
            $hold = $again;
            $run->update_data( $db, { booking_hold => { %$booking, hold_id => $hold->id } } );
        }

        my $version = Registry::DAO::OfferVersion->find( $db, { id => $payment->offer_version_id } );
        my $ends;
        if ( ( $version->policies->{expiry}{kind} // '' ) eq 'end_of_occurrence' ) {
            ( undef, $ends ) = Registry::DAO::Resource->find( $db, { id => $hold->resource_id } )->occurrence_window($db);
        }
        $hold->convert( $db, {
            holder_user_id      => $payment->user_id,
            offer_version_id    => $payment->offer_version_id,
            payment_plan_id     => $payment->metadata->{payment_plan_id},
            starts_at           => 'now',
            ends_at             => $ends,
            payment_id          => $payment->id,
            payment_share_cents => $payment->amount_cents,
            terms_version       => $terms,
        } );
        $tx->commit if $tx;
        return {};
    }

    # Nothing to ask: the controller completes it as soon as the run reaches it.
    method nothing_to_ask ( $db, $run ) { 1 }

    # The booking this run made, as its pages show it: the offer, how many,
    # the seats, the class's local start and the policies it was sold under.
    method prepare_template_data ( $db, $run, $params = {} ) {
        $db = $db->db if $db isa Registry::DAO;
        my $id = $run->data->{owed_payment_id};
        my ($e) = defined $id && !ref $id && $id =~ $UUID
            ? Registry::DAO::Entitlement->created_by_payment( $db, $id ) : ();
        return {} unless $e;
        my $version = $e->offer_version($db);
        my ($resource) = map { scalar Registry::DAO::Resource->find( $db, { id => $_ } ) }
            $db->select( 'entitlement_units', 'DISTINCT resource_id', { entitlement_id => $e->id } )->arrays->flatten->each;
        return { booking => {
            entitlement_id => $e->id,
            offer          => $db->select( 'offers', 'name', { id => $version->offer_id } )->array->[0],
            count          => $run->data->{booking_hold}{count},
            seats          => scalar $e->units( $db, $resource->id )->@*,
            start          => Registry::DAO::Event->find( $db, { id => $resource->event_id } )->local_start($db),
            policy         => Registry::DAO::WorkflowSteps::ChooseOfferAndUnits->policy_words($version),
        } };
    }

    # This run's own payment, completed for exactly what it owes under the
    # stamped version and plan, or undef.
    method _paid ( $db, $run, $data ) {
        my ( $id, $owed ) = $data->@{qw( owed_payment_id owed_payment )};
        return undef unless defined $id && !ref $id && $id =~ $UUID && ref $owed eq 'HASH';
        my $payment = Registry::DAO::Payment->find( $db, { id => $id } ) or return undef;
        return $payment->status eq 'completed'
            && ( $payment->metadata->{workflow_run_id} // '' ) eq $run->id
            && $payment->amount_cents == ( $owed->{amount_cents} // -1 )
            && ( $payment->offer_version_id // '' ) eq ( $owed->{offer_version_id} // "\0" )
            && ( $payment->metadata->{payment_plan_id} // '' ) eq ( $owed->{payment_plan} // "\0" )
            ? $payment : undef;
    }

    sub _stay ($why) { return { stay => 1, errors => [$why] } }
}

1;
