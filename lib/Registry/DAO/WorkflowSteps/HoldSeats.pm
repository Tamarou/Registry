# ABOUTME: in-studio-booking step: re-checks the occurrence, offer and count, then holds count x seats per unit for the run.
# ABOUTME: Writes what the payment step owes, against the hold, from the run's chosen offer only; a resubmit keeps the one hold.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::HoldSeats :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Offer;
    use Registry::DAO::OfferVersion;
    use Registry::DAO::WorkflowSteps::ChooseOfferAndUnits;
    use Registry::PriceOps::Hold;

    # Long enough to pay; the step's metadata may say otherwise.
    my $HOLD_MINUTES = 15;

    method process ( $db, $form_data, $run = undef ) {
        my $tx = $db->dbh->{AutoCommit} ? $db->begin : undef;
        # One booking hold per run: a second submit waits on the run's row.
        my $data = $db->query( 'SELECT data FROM workflow_runs WHERE id = ? FOR UPDATE', $run->id )
            ->expand->hash->{data} // {};
        # Once a charge started against the hold, the hold stays: a charge
        # never ends up pointing at a released one.
        return { stay => 1, errors => ['This booking is already being paid for'] }
            if defined $data->{owed_payment_id};

        # Gives back whatever the run held, so a refused hold holds nothing.
        my sub refuse ($why) {
            $db->query( q{UPDATE holds SET state = 'released' WHERE workflow_run_id = ? AND state = 'held'}, $run->id );
            $run->update_data( $db, { booking_hold => undef, owed_payment => undef } );
            $tx->commit if $tx;
            return { stay => 1, errors => [$why] };
        }

        my $user = ref $data->{user} eq 'HASH' ? $data->{user} : {};
        return refuse('Sign in to book') unless length( $user->{id} // '' );
        # Stamped on the booking when it is granted, so none is held without it.
        return refuse('Agree to the terms of service to book.') unless length( $data->{agreed_terms_version} // '' );
        my ( $occurrence_id, $version_id, $count ) = $data->@{qw( booking_occurrence_id booking_offer_version_id booking_count )};
        # The occurrence may have started or closed, or the offer changed, since they were chosen.
        if ( my $refusal = Registry::DAO::WorkflowSteps::ChooseOfferAndUnits->refusal( $db, $occurrence_id, $version_id, $count ) ) {
            return refuse($refusal);
        }
        my $version = Registry::DAO::OfferVersion->find( $db, { id => $version_id } );
        my $seats   = $version->seats_for($count);

        # A resubmit keeps the one hold while it is live and for the same seats;
        # anything else the run held (lapsed, or for another choice) is given back.
        my $live = Registry::PriceOps::Hold->live_sql('holds');
        my $kept = $db->query( "SELECT id FROM holds WHERE workflow_run_id = ? AND resource_id = ? AND units = ? AND $live",
            $run->id, $occurrence_id, $seats )->array;
        $db->query( q{UPDATE holds SET state = 'released' WHERE workflow_run_id = ? AND state = 'held' AND id IS DISTINCT FROM ?},
            $run->id, $kept && $kept->[0] );
        my $hold_id = $kept && $kept->[0];
        unless ($hold_id) {
            # The page read the room unlocked; place re-checks it under the occurrence's lock.
            my $minutes = $self->metadata->{hold_minutes} // $HOLD_MINUTES;
            my $hold = eval {
                Registry::PriceOps::Hold->place( $db, {
                    resource_id     => $occurrence_id,
                    units           => $seats,
                    workflow_run_id => $run->id,
                    expires_at      => \[ 'clock_timestamp() + make_interval(mins => ?)', $minutes ],
                } );
            };
            unless ($hold) {
                die $@ unless $@ =~ /units free/;
                return refuse("That class no longer has room for $seats");
            }
            $hold_id = $hold->id;
        }

        my ($plan) = grep { $_->{kind} eq 'one_time' } $version->payment_plans($db)->@*;
        my $name = Registry::DAO::Offer->find( $db, { id => $version->offer_id } )->name;
        # Written with the hold, under the run's lock. owed_payment is what the
        # payment step charges; booking_hold is what completing the booking converts.
        $run->update_data( $db, {
            user_id      => $user->{id},
            booking_hold => {
                hold_id          => $hold_id,
                occurrence_id    => $occurrence_id,
                offer_version_id => $version->id,
                count            => 0 + $count,
                seats            => $seats,
            },
            owed_payment => {
                offer_version_id => $version->id,
                payment_plan     => $plan->{id},
                amount_cents     => $count * $version->price_cents,
                description      => "$name x $count",
                purpose          => 'booking',
                hold_id          => $hold_id,
            },
        } );
        $tx->commit if $tx;
        return {};
    }

    method prepare_template_data ( $db, $run, $params = {} ) {
        my ( $version_id, $count ) = $run->data->@{qw( booking_offer_version_id booking_count )};
        return {} unless ( $count // '' ) =~ /\A[0-9]+\z/
            && ( $version_id // '' ) =~ /\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/i;
        my $version = Registry::DAO::OfferVersion->find( $db, { id => $version_id } ) or return {};
        return {
            quote => {
                offer => Registry::DAO::Offer->find( $db, { id => $version->offer_id } )->name,
                count => $count,
                seats => $count * $version->units_per_acceptance,
                total => sprintf( '%.2f', $count * $version->price_cents / 100 ),
            },
        };
    }
}

1;
