# ABOUTME: session-checkout step: once the cart is paid, turns each line's hold into its child's entitlement, paid by the parent, once.
# ABOUTME: A line whose seat is gone is refunded its share alone (the whole cart if a surviving price no longer qualifies); instalments are scheduled.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::CompleteSessionCheckout :isa(Registry::DAO::WorkflowStep) {
    use Mojo::JSON qw( encode_json );
    use Mojo::Promise;
    use Registry::DAO::FamilyMember;
    use Registry::DAO::Notification;
    use Registry::DAO::OfferVersion;
    use Registry::DAO::Payment;
    use Registry::DAO::Resource;
    use Registry::DAO::WorkflowSteps::SessionCart;
    use Registry::Job::InstalmentSchedule;
    use Registry::PriceOps::Hold;
    use Registry::PriceOps::Instalments ();

    my $UUID = qr/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i;

    method process ( $db, $form_data, $run = undef ) {
        $db = $db->db if $db isa Registry::DAO;
        my $tx = $db->dbh->{AutoCommit} ? $db->begin : undef;
        # The person's return and the driver may both arrive: the second waits
        # here and finds the checkout already decided.
        my $data = $db->query( 'SELECT data FROM workflow_runs WHERE id = ? FOR UPDATE', $run->id )
            ->expand->hash->{data} // {};
        if ( ref $data->{checkout_outcome} eq 'HASH' ) {
            $tx->commit if $tx;
            # A schedule whose job was never queued (the process died after
            # the COMMIT) is queued now; enqueue skips one already waiting.
            $self->_schedule( $db, $run, $data->{owed_payment_id}, $data->{checkout_outcome} );
            return $self->_refund( $db, $run, $data->{checkout_outcome} );
        }

        my $payment = $self->_paid( $db, $run, $data );
        return _stay('This booking has not been paid for yet') unless $payment;
        # Stamped on each entitlement at insert (ADR 005, ruling 12).
        my $terms = $data->{agreed_terms_version};
        return _stay('Agree to the terms of service to book.') unless defined $terms && !ref $terms && length $terms;
        my @lines = $payment->metadata->{lines}->@*;
        my $charged = $db->query( q{SELECT to_char(completed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD')
                                      FROM payments WHERE id = ?}, $payment->id )->array->[0];

        # Each line's seat: its hold while live; a lapsed one is taken again
        # if its session still has room, otherwise the line is lost. Sessions
        # are locked in id order, so two checkouts never deadlock.
        my $live = Registry::PriceOps::Hold->live_sql('holds');
        my ( %hold, %lost );
        for my $line ( sort { $a->{resource_id} cmp $b->{resource_id} } @lines ) {
            my $key = _key($line);
            my $session = Registry::DAO::Resource->locked( $db, $line->{resource_id} );
            # A session that started while the parent paid is not booked (ruling 7a).
            unless ( $session->on_sale($db) ) {
                $db->query( q{UPDATE holds SET state = 'released' WHERE id = ? AND state = 'held'}, $line->{hold_id} );
                $lost{$key} = 'started';
                next;
            }
            my $held = $db->query( "SELECT $live FROM holds WHERE id = ? AND workflow_run_id = ? AND resource_id = ?",
                $line->{hold_id}, $run->id, $line->{resource_id} )->array;
            if ( $held && $held->[0] ) { $hold{$key} = $line->{hold_id}; next }
            $db->query( q{UPDATE holds SET state = 'released' WHERE id = ? AND state = 'held'}, $line->{hold_id} );
            my $again = eval {
                Registry::PriceOps::Hold->place( $db, {
                    resource_id     => $line->{resource_id},
                    units           => 1,
                    workflow_run_id => $run->id,
                    expires_at      => \"clock_timestamp() + interval '1 minute'",    # converted below
                } );
            };
            if ($again) { $hold{$key} = $again->id; next }
            die $@ unless $@ =~ /units free/;
            $lost{$key} = 'full';
        }

        # An instalment line's parts are dated from the charge's UTC date, as
        # the schedule's start compares them (Payment::instalment_schedule_start);
        # the hold dated them before the charge. A plan that, so dated, would
        # end after its session's last day no longer fits: refused, never clamped.
        my %parts;
        for my $line ( grep { !$lost{ _key($_) } && $_->{kind} eq 'instalments' } @lines ) {
            my $version = Registry::DAO::OfferVersion->find( $db, { id => $line->{offer_version_id} } );
            my ($plan)  = grep { $_->{id} eq $line->{payment_plan_id} } $version->payment_plans($db)->@*;
            $parts{ _key($line) } = $line->{parts}[0]{due_date} eq $charged ? $line->{parts}
                : Registry::PriceOps::Instalments::parts( $version->price_cents, $plan, $charged );
            $lost{ _key($line) } = 'plan_ends_late'
                unless Registry::PriceOps::Instalments::fits( $plan, $charged, $self->_last_day( $db, $line->{resource_id} ) );
        }

        # A price may have counted a sibling whose line is lost (a sibling
        # price): each surviving line's price is asked again, at the moment
        # its seat was held, without the lost lines. One that no longer
        # qualifies refunds the whole cart.
        if (%lost) {
            my @earlier;
            for my $line ( grep { !$lost{ _key($_) } } @lines ) {
                my $version = Registry::DAO::OfferVersion->find( $db, { id => $line->{offer_version_id} } );
                my $unmet   = $version->unmet_conditions( $db, {
                    holder_family_member_id => $line->{family_member_id},
                    at         => $self->_held_at( $db, $line->{hold_id} ),
                    cart_lines => [@earlier],
                } );
                if (@$unmet) { $lost{ _key($_) } //= 'sibling' for @lines; last }
                push @earlier, { family_member_id => $line->{family_member_id}, offer_id => $version->offer_id };
            }
        }

        my ( %booked, @refunds );
        for my $line (@lines) {
            my $key = _key($line);
            if ( $lost{$key} ) {
                $db->query( q{UPDATE holds SET state = 'released' WHERE id = ? AND state = 'held'}, $hold{$key} )
                    if $hold{$key};
                push @refunds, {
                    $line->%{qw( family_member_id resource_id )},
                    payment_id      => $payment->id,
                    amount_cents    => $line->{share_cents},
                    idempotency_key => join( ':', 'refund:session-line', $run->id, $key ),
                    reason          => $lost{$key},
                };
                next;
            }
            my $version  = Registry::DAO::OfferVersion->find( $db, { id => $line->{offer_version_id} } );
            my $resource = Registry::DAO::Resource->find( $db, { id => $line->{resource_id} } );
            my ( undef, $ends ) = ( $version->policies->{expiry}{kind} // '' ) eq 'end_of_occurrence'
                ? $resource->occurrence_window($db) : ();
            my $entitlement = Registry::PriceOps::Hold->find( $db, { id => $hold{$key} }, 'id' )->convert( $db, {
                holder_family_member_id => $line->{family_member_id},
                payer_user_id           => $payment->user_id,
                offer_version_id        => $line->{offer_version_id},
                payment_plan_id         => $line->{payment_plan_id},
                starts_at               => 'now',
                ends_at                 => $ends,
                payment_id              => $payment->id,
                payment_share_cents     => $line->{share_cents},
                terms_version           => $terms,
            } );
            $booked{$key} = $entitlement->id;
        }
        $self->_store_parts( $db, $payment, { map { $_ => $parts{$_} } grep { $booked{$_} } keys %parts } );

        my $outcome = { booked => \%booked, refunds => \@refunds };
        $run->update_data( $db, { checkout_outcome => $outcome } );
        $self->_confirm( $db, $run, $payment, [ grep { $booked{ _key($_) } } @lines ] ) if %booked;
        $self->_tell( $db, $run, $payment, \@refunds ) if @refunds;
        $tx->commit if $tx;

        $self->_schedule( $db, $run, $payment->id, $outcome );
        return $self->_refund( $db, $run, $outcome );
    }

    # After the COMMIT: each booked instalment child's Stripe schedule is made
    # by a retried job, keyed by its entitlement (Job::InstalmentSchedule),
    # unless one is recorded already.
    method _schedule ( $db, $run, $payment_id, $outcome ) {
        my $payment = defined $payment_id && !ref $payment_id && $payment_id =~ $UUID
            && Registry::DAO::Payment->find( $db, { id => $payment_id } ) or return;
        my $slug = $payment->metadata->{tenant_slug};
        my @scheduled = grep { !Registry::DAO::Payment->instalment_schedule_of( $db, $_ ) }
            map { $outcome->{booked}{ _key($_) } // () } grep { $_->{kind} eq 'instalments' } $payment->metadata->{lines}->@*;
        for my $eid (@scheduled) {
            try { Registry::Job::InstalmentSchedule->enqueue( Registry::Job::InstalmentSchedule->minion,
                    instalment_schedule => $eid, $slug ) }
            catch ($e) {
                Registry::DAO::Notification->alert_admins( $db, 'Instalments were not queued: schedule them by hand',
                    "Registry booked entitlement $eid (tenant $slug) on instalments but could not queue its "
                    . 'Stripe schedule, so only its first payment was taken. Ask Registry support to schedule '
                    . "the rest. ($e)", { entitlement_id => $eid, workflow_run_id => $run->id } );
            }
        }
    }

    # Session $resource_id's last day, in its location's zone.
    method _last_day ( $db, $resource_id ) {
        return $db->query( q{
            SELECT max(to_char(e.time AT TIME ZONE l.time_zone, 'YYYY-MM-DD'))
              FROM events e JOIN locations l ON l.id = e.location_id WHERE e.session_resource_id = ?
        }, $resource_id )->array->[0];
    }

    sub _key ($line) { "$line->{family_member_id}:$line->{resource_id}" }

    # The instant hold $hold_id was placed, as conditions are asked at it.
    method _held_at ( $db, $hold_id ) {
        return $db->query( q{SELECT to_char(placed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
                               FROM holds WHERE id = ?}, $hold_id )->array->[0];
    }

    # Stores the booked instalment lines' parts as re-dated from the charge
    # (%$parts, by line key), which the schedule and the confirmation read.
    method _store_parts ( $db, $payment, $parts ) {
        my @lines = map { $parts->{ _key($_) } ? { %$_, parts => $parts->{ _key($_) } } : $_ }
            $payment->metadata->{lines}->@*;
        $db->query( q{UPDATE payments SET metadata = jsonb_set(metadata, '{lines}', ?::jsonb) WHERE id = ?},
            encode_json( \@lines ), $payment->id ) if %$parts;
    }

    my sub dollars ($cents) { sprintf '$%.2f', $cents / 100 }

    # Each booked line in the payer's words: child, session, its days in its
    # location's zone, the price, the plan with its due dates, and the policies.
    method line_words ( $db, $line, $payment_lines = undef ) {
        my $child   = Registry::DAO::FamilyMember->find( $db, { id => $line->{family_member_id} } )->child_name;
        my $version = Registry::DAO::OfferVersion->find( $db, { id => $line->{offer_version_id} } );
        my $days    = $db->query( q{
            SELECT r.name, l.name AS location, l.time_zone,
                   to_char(min(e.time AT TIME ZONE l.time_zone), 'YYYY-MM-DD') AS first_day,
                   to_char(max(e.time AT TIME ZONE l.time_zone), 'YYYY-MM-DD') AS last_day,
                   to_char(min(e.time AT TIME ZONE l.time_zone), 'HH24:MI') AS start
              FROM resources r JOIN events e ON e.session_resource_id = r.id JOIN locations l ON l.id = e.location_id
             WHERE r.id = ? GROUP BY r.name, l.name, l.time_zone
        }, $line->{resource_id} )->hash;
        my $plan = $line->{kind} eq 'instalments'
            ? sprintf( '%s in %d payments: %s.', dollars( $version->price_cents ), scalar $line->{parts}->@*,
                join ', ', map { dollars( $line->{parts}[$_]{amount_cents} )
                    . ( $_ ? " due $line->{parts}[$_]{due_date}" : " paid $line->{parts}[$_]{due_date}" ) }
                    0 .. $#{ $line->{parts} } )
            : sprintf( '%s, paid in full.', dollars( $version->price_cents ) );
        return {
            child    => $child,
            session  => $days->{name},
            location => $days->{location},
            dates    => "$days->{first_day} to $days->{last_day}, from $days->{start} ($days->{time_zone})",
            plan     => $plan,
            policy   => Registry::DAO::WorkflowSteps::SessionCart->policy_words($version),
        };
    }

    # The payer's confirmation, once, when the checkout is decided.
    method _confirm ( $db, $run, $payment, $lines ) {
        # The parts as stored, dated from the charge.
        my %parts = map { _key($_) => $_->{parts} }
            Registry::DAO::Payment->find( $db, { id => $payment->id } )->metadata->{lines}->@*;
        my @words = map { $self->line_words( $db, { %$_, parts => $parts{ _key($_) } } ) } @$lines;
        my @text  = map { "$_->{child}: $_->{session}, $_->{dates}. $_->{plan} " . join ' ', $_->{policy}->@* } @words;
        Registry::DAO::Notification->create( $db, {
            user_id  => $payment->user_id, type => 'enrollment_confirmation', channel => 'email',
            subject  => 'Booking confirmed: ' . join( ', ', map { $_->{child} } @words ),
            message  => join( "\n\n", @text ),
            metadata => {
                workflow_run_id => $run->id, payment_id => $payment->id, lines => \@text,
                event_name => $words[0]{session}, location_name => $words[0]{location}, start_date => $words[0]{dates},
            },
        } );
    }

    # Why a paid line is not booked, in the payer's words.
    my %WHY = (
        full    => '%2$s had no room left for %1$s by the time the payment went through',
        sibling => "%1\$s's price was for a child whose brother or sister also has a place, and that place could not be made",
        started => '%2$s had already started by the time the payment went through',
        plan_ends_late => "%1\$s's payment plan would end after the last day of %2\$s, as the payment went through on "
            . 'a later day than the seats were held',
    );

    # The payer and the studio's admins, told once, when the refunds are decided.
    method _tell ( $db, $run, $payment, $refunds ) {
        my @why = map {
            my $child   = Registry::DAO::FamilyMember->find( $db, { id => $_->{family_member_id} } )->child_name;
            my $session = Registry::DAO::Resource->find( $db, { id => $_->{resource_id} } )->name;
            sprintf( "$WHY{ $_->{reason} }, so %1\$s is not booked into %2\$s; %3\$s is being refunded.",
                $child, $session, dollars( $_->{amount_cents} ) )
        } @$refunds;
        my $meta = { workflow_run_id => $run->id, payment_id => $payment->id };
        Registry::DAO::Notification->create( $db, {
            user_id  => $payment->user_id, type => 'general', channel => 'email',
            subject  => 'Part of your booking could not be made: it is refunded',
            message  => join( ' ', @why ) . ' A refund can take 5-10 business days to show on your statement.',
            metadata => $meta,
        } );
        Registry::DAO::Notification->alert_admins( $db, 'A paid cart line could not be booked: it is being refunded',
            sprintf( 'Payment %s (%s) was made after a seat hold lapsed. %s Registry is refunding each such line; '
                . 'the platform fee is kept.', $payment->id, dollars( $payment->amount_cents ), join ' ', @why ),
            $meta );
    }

    # Refunds each lost line its share, under a key for the run and line, so
    # the driver's retries and the person's return ask Stripe once. A failure
    # is recorded on the payment and handed to the driver to retry. A cart with
    # nothing booked stays here, saying so.
    method _refund ( $db, $run, $outcome ) {
        my @refunds = ( $outcome->{refunds} // [] )->@*;
        my %booked  = %{ $outcome->{booked} // {} };
        my sub name ($id) { Registry::DAO::FamilyMember->find( $db, { id => $id } )->child_name }
        my $told = %booked
            ? join( ' ', ( map { name( ( split /:/ )[0] ) . ' is booked.' } sort keys %booked ),
                map { sprintf '%s could not be booked; %s for %s is being refunded.', name( $_->{family_member_id} ),
                      dollars( $_->{amount_cents} ), name( $_->{family_member_id} ) } @refunds )
            : 'Nothing could be booked, as the seats held for you were let go before your payment went through. '
            . 'Your payment is being refunded in full.';
        my $done = %booked ? {} : _stay($told);
        return $done unless @refunds;
        my $payment = Registry::DAO::Payment->find( $db, { id => $refunds[0]{payment_id} } );
        my $chain   = Mojo::Promise->resolve;
        my $asking;    # the key of the refund in flight, named on its failure
        for my $refund (@refunds) {
            $chain = $chain->then( sub (@) {
                $asking = $refund->{idempotency_key};
                $payment->refund_async( $db, { $refund->%{qw( amount_cents idempotency_key )} } );
            } );
        }
        return $chain->then(
            sub (@) { $done },
            sub ($error) {
                $payment->record_refund_failure( $db, $error, $asking );
                return { %{ _stay($told) },
                    retry => sprintf( "cart line refund of payment %s on run %s failed: %s\n",
                        $payment->id, $run->id, "$error" =~ s/\s+\z//r ) };
            },
        );
    }

    # Nothing to ask until the checkout is decided: the controller completes it
    # as soon as the run reaches it, and shows the done page once it is.
    method nothing_to_ask ( $db, $run ) { ref $run->data->{checkout_outcome} ne 'HASH' }

    # The bookings this run made and the lines it refunded, in words.
    method prepare_template_data ( $db, $run, $params = {} ) {
        $db = $db->db if $db isa Registry::DAO;
        my $outcome = $run->data->{checkout_outcome};
        my $id      = $run->data->{owed_payment_id};
        return {} unless ref $outcome eq 'HASH' && defined $id && !ref $id && $id =~ $UUID;
        my $payment = Registry::DAO::Payment->find( $db, { id => $id } ) or return {};
        my @lines   = $payment->metadata->{lines}->@*;
        my %refunded = map { _key($_) => $_ } ( $outcome->{refunds} // [] )->@*;
        return {
            booked   => [ map { $self->line_words( $db, $_ ) } grep { $outcome->{booked}{ _key($_) } } @lines ],
            refunded => [ map { {
                child  => Registry::DAO::FamilyMember->find( $db, { id => $_->{family_member_id} } )->child_name,
                amount => dollars( $refunded{ _key($_) }{amount_cents} ) } } grep { $refunded{ _key($_) } } @lines ],
        };
    }

    # This run's own payment, completed for exactly the cart it owes, or undef.
    method _paid ( $db, $run, $data ) {
        my ( $id, $owed ) = $data->@{qw( owed_payment_id owed_payment )};
        return undef unless defined $id && !ref $id && $id =~ $UUID && ref $owed eq 'HASH';
        my $payment = Registry::DAO::Payment->find( $db, { id => $id } ) or return undef;
        my $lines   = $payment->metadata->{lines};
        return $payment->status eq 'completed'
            && ( $payment->metadata->{workflow_run_id} // '' ) eq $run->id
            && $payment->amount_cents == ( $owed->{amount_cents} // -1 )
            && !defined $payment->offer_version_id
            && ref $lines eq 'ARRAY' && @$lines
            ? $payment : undef;
    }

    sub _stay ($why) { return { stay => 1, errors => [$why] } }
}

1;
