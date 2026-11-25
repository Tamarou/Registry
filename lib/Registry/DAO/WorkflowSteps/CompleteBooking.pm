# ABOUTME: in-studio-booking step: once the booking is paid, turns the run's hold into the booker's entitlement, once.
# ABOUTME: Reads only server-owned run data; the entitlement is linked to its payment and stamped with the agreed terms at insert.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::CompleteBooking :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Entitlement;
    use Registry::DAO::Event;
    use Registry::DAO::Notification;
    use Registry::DAO::OfferVersion;
    use Registry::DAO::WorkflowSteps::ChooseOfferAndUnits;
    use Registry::DAO::Payment;
    use Registry::DAO::Resource;
    use Registry::PriceOps::Hold;
    use Mojo::Promise;

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
        # Decided once: the booking was not made and its payment is refunded.
        if ( ref $data->{booking_refund} eq 'HASH' ) {
            $tx->commit if $tx;
            return $self->_refund( $db, $run, $data->{booking_refund} );
        }

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
            unless ($again) {
                die $@ unless $@ =~ /units free/;
                # They do not: nothing is booked and the whole charge is
                # refunded, despite a refund-none policy, which governs the
                # booker's cancellations, not this race (ruling 7a).
                my $refund = {
                    payment_id      => $payment->id,
                    amount_cents    => $payment->amount_cents,
                    idempotency_key => 'refund:booking:' . $run->id,
                };
                $run->update_data( $db, { booking_refund => $refund } );
                $self->_tell( $db, $run, $payment, $hold->units );
                $tx->commit if $tx;
                return $self->_refund( $db, $run, $refund );
            }
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

    # The booker and the studio's admins, told once, when the refund is decided.
    method _tell ( $db, $run, $payment, $seats ) {
        my $sum  = sprintf '$%.2f', $payment->amount_cents / 100;
        my $meta = { workflow_run_id => $run->id, payment_id => $payment->id };
        Registry::DAO::Notification->create( $db, {
            user_id  => $payment->user_id, type => 'general', channel => 'email',
            subject  => 'Your booking could not be made: your payment is refunded',
            message  => "Your payment went through after the seats we held for you were let go, and the class "
                      . "has no room left, so you are not booked. Your payment of $sum is being refunded in full; "
                      . 'it can take 5-10 business days to show on your statement.',
            metadata => $meta,
        } );
        Registry::DAO::Notification->alert_admins( $db,
            'A paid booking could not be made: it is being refunded',
            sprintf( 'Payment %s (%s) was made after its seat hold lapsed, and the class had no room left for %d '
                . 'seats. Nothing was booked. Registry is refunding the payment in full; the platform fee is kept.',
                $payment->id, $sum, $seats ),
            $meta );
    }

    # Refunds a paid booking that was not made, in full, under a key for the
    # run, so the driver's retries and the person's return ask Stripe once.
    # The platform's fee is kept, as on every refund (ADR 003). A failure is
    # recorded on the payment and handed to the driver to retry; its last
    # attempt puts the run before the admins.
    method _refund ( $db, $run, $refund ) {
        my $payment = Registry::DAO::Payment->find( $db, { id => $refund->{payment_id} } );
        my $told = sprintf 'The class filled up before your payment went through, so you are not booked. '
            . 'Your payment of $%.2f is being refunded in full.', $refund->{amount_cents} / 100;
        # From a resolved promise, so a guard's die is a rejection handled below.
        return Mojo::Promise->resolve->then( sub {
            $payment->refund_async( $db, { $refund->%{qw( amount_cents idempotency_key )} } );
        } )->then(
            sub ($) { _stay($told) },
            sub ($error) {
                $payment->record_refund_failure( $db, $error );
                return { %{ _stay($told) },
                    retry => sprintf( "booking refund of payment %s on run %s failed: %s\n",
                        $payment->id, $run->id, "$error" =~ s/\s+\z//r ) };
            },
        );
    }

    # Nothing to ask until the booking is made: the controller completes it as
    # soon as the run reaches it, and shows the done page once it is made.
    method nothing_to_ask ( $db, $run ) {
        my $booking = $run->data->{booking_hold};
        my $hold_id = ref $booking eq 'HASH' ? $booking->{hold_id} : undef;
        return 1 unless defined $hold_id && !ref $hold_id && $hold_id =~ $UUID;
        return ( $db->select( 'holds', 'state', { id => $hold_id } )->array // [''] )->[0] ne 'converted';
    }

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
