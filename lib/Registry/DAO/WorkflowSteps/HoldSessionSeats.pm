# ABOUTME: session-checkout step: asks the whole cart again at this instant, the purchase moment, then holds one seat per line.
# ABOUTME: Writes the cart's one owed charge, each child's first charge summed, with every line's share; a refusal releases every hold.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::HoldSessionSeats :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Family;
    use Registry::DAO::FamilyMember;
    use Registry::DAO::OfferVersion;
    use Registry::DAO::Resource;
    use Registry::DAO::WorkflowSteps::SessionCart;
    use Registry::PriceOps::Hold;
    use Registry::PriceOps::Instalments qw( parts );

    my $CART = 'Registry::DAO::WorkflowSteps::SessionCart';

    # Long enough to pay; the step's metadata may say otherwise.
    my $HOLD_MINUTES = 15;

    method process ( $db, $form_data, $run = undef ) {
        my $tx = $db->dbh->{AutoCommit} ? $db->begin : undef;
        # One set of holds per run: a second submit waits on the run's row.
        my $data = $db->query( 'SELECT data FROM workflow_runs WHERE id = ? FOR UPDATE', $run->id )
            ->expand->hash->{data} // {};
        # Once a charge started against the holds, they stay: a charge never
        # ends up pointing at a released one.
        return { stay => 1, errors => ['This cart is already being paid for'] }
            if defined $data->{owed_payment_id};

        # Gives back whatever the run held, so a refused cart holds nothing.
        my sub refuse ($why) {
            $db->query( q{UPDATE holds SET state = 'released' WHERE workflow_run_id = ? AND state = 'held'}, $run->id );
            $run->update_data( $db, { cart_holds => undef, owed_payment => undef } );
            $tx->commit if $tx;
            return { stay => 1, errors => [$why] };
        }

        # Stamped on each entitlement when it is granted, so none is held without it.
        return refuse('Agree to the terms of service to book.') unless length( $data->{agreed_terms_version} // '' );
        my $lines = ref $data->{cart_lines} eq 'ARRAY' ? $data->{cart_lines} : [];
        return refuse('Choose a session for at least one child') unless @$lines;
        # The hold's moment is the purchase moment: a session may have filled,
        # a price ended or a plan stopped fitting since the cart. The cart
        # listed every line's price, so one it would not list now is no longer
        # offered (an early-bird deadline passed, or a new version replaced it).
        if ( my $why = $CART->refusal( $db, $data, $lines, $run->id ) ) {
            return refuse( $why eq $CART->unlisted
                ? 'A price in your cart is no longer offered. Go back to your cart and choose again.' : $why );
        }

        # A resubmit keeps each line's hold while it is live; anything else the
        # run held (lapsed, or for a line since removed) is given back.
        my $live = Registry::PriceOps::Hold->live_sql('holds');
        my $had  = ref $data->{cart_holds} eq 'HASH' ? $data->{cart_holds} : {};
        my %holds;
        for my $line (@$lines) {
            my $key  = "$line->{family_member_id}:$line->{resource_id}";
            my $kept = defined $had->{$key} && $db->query(
                "SELECT id FROM holds WHERE id::text = ? AND workflow_run_id = ? AND resource_id = ? AND units = 1 AND $live",
                $had->{$key}, $run->id, $line->{resource_id} )->array;
            $holds{$key} = $kept ? $kept->[0] : undef;
        }
        $db->query( q{UPDATE holds SET state = 'released'
                       WHERE workflow_run_id = ? AND state = 'held' AND NOT (id = ANY(?::uuid[]))},
            $run->id, [ grep {defined} values %holds ] );

        # All or nothing, each under its session's lock, taken in id order so
        # two carts never deadlock; the cart read the room unlocked.
        my $minutes = $self->metadata->{hold_minutes} // $HOLD_MINUTES;
        my $live_h  = Registry::PriceOps::Hold->live_sql('h');
        for my $line ( sort { $a->{resource_id} cmp $b->{resource_id} } @$lines ) {
            my $key = "$line->{family_member_id}:$line->{resource_id}";
            next if $holds{$key};
            # Under the session's lock, so a second tab waits for the first's
            # holds and cart_holds, written together, before it looks.
            Registry::DAO::Resource->locked( $db, $line->{resource_id} );
            return refuse( sprintf '%s is already being booked into %s in another checkout',
                Registry::DAO::FamilyMember->find( $db, { id => $line->{family_member_id} } )->child_name,
                Registry::DAO::Resource->find( $db, { id => $line->{resource_id} } )->name )
                if $db->query( qq{
                    SELECT EXISTS (SELECT 1 FROM holds h JOIN workflow_runs r ON r.id = h.workflow_run_id
                                    WHERE h.resource_id = ? AND h.workflow_run_id <> ? AND $live_h
                                      AND r.data->'cart_holds'->>? = h.id::text)
                }, $line->{resource_id}, $run->id, $key )->array->[0];
            my $hold = eval {
                Registry::PriceOps::Hold->place( $db, {
                    resource_id     => $line->{resource_id},
                    units           => 1,
                    workflow_run_id => $run->id,
                    expires_at      => \[ 'clock_timestamp() + make_interval(mins => ?)', $minutes ],
                } );
            };
            unless ($hold) {
                die $@ unless $@ =~ /units free/;
                return refuse( sprintf '%s no longer has room for %s',
                    Registry::DAO::Resource->find( $db, { id => $line->{resource_id} } )->name,
                    Registry::DAO::FamilyMember->find( $db, { id => $line->{family_member_id} } )->child_name );
            }
            $holds{$key} = $hold->id;
        }

        # One charge for the cart: a one-time line's share is its price, an
        # instalment line's its first part; the rest are scheduled per child.
        my @owed = map {
            my $line    = $_;
            my $version = Registry::DAO::OfferVersion->find( $db, { id => $line->{offer_version_id} } );
            my ($plan)  = grep { $_->{id} eq $line->{payment_plan_id} } $version->payment_plans($db)->@*;
            my $parts   = $plan->{kind} eq 'instalments'
                ? parts( $version->price_cents, $plan, $self->today( $db, $line->{resource_id} ) ) : undef;
            +{ $line->%{qw( family_member_id resource_id offer_version_id payment_plan_id )},
              kind        => $plan->{kind},
              share_cents => $parts ? $parts->[0]{amount_cents} : $version->price_cents,
              parts       => $parts,
              hold_id     => $holds{"$line->{family_member_id}:$line->{resource_id}"} }
        } @$lines;
        my $total = 0;
        $total += $_->{share_cents} for @owed;

        # Written with the holds, under the run's lock. owed_payment is what the
        # payment step charges; cart_holds is what completing the checkout converts.
        $run->update_data( $db, {
            cart_holds   => \%holds,
            owed_payment => { purpose => 'session_checkout', amount_cents => $total, lines => \@owed },
        } );
        $tx->commit if $tx;
        return {};
    }

    # Session $resource_id's today, as InstalmentPaymentPlan judges a plan's
    # fit: the latest local today among its days' locations.
    method today ( $db, $resource_id ) {
        return $db->query( q{
            SELECT max(to_char(now() AT TIME ZONE l.time_zone, 'YYYY-MM-DD'))
              FROM events e JOIN locations l ON l.id = e.location_id
             WHERE e.session_resource_id = ?
        }, $resource_id )->array->[0];
    }

    # The cart in words, as the cart page showed it.
    method prepare_template_data ( $db, $run, $params = {} ) {
        my $data  = $run->data // {};
        my $lines = ref $data->{cart_lines} eq 'ARRAY' ? $data->{cart_lines} : [];
        my $payer = $data->{user_id};
        return { lines => [] } unless defined $payer && !ref $payer
            && $payer =~ /\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/i;
        my %name = map { $_->id => $_->child_name } Registry::DAO::Family->list_children( $db, $payer )->@*;
        # cart_lines is server-owned: only lines the cart accepted reach here.
        return { lines => $CART->summary( $db, $lines, \%name ) };
    }
}

1;
