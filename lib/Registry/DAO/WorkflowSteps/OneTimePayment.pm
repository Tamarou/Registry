# ABOUTME: Workflow step charging a one-time payment for what a prior step owes under a stamped offer version.
# ABOUTME: A direct charge on the seller's account with the revenue-share fee; hands the run on once it is paid.
use 5.42.0;

use Object::Pad;

class Registry::DAO::WorkflowSteps::OneTimePayment :isa(Registry::DAO::WorkflowStep) {

use Registry::DAO::Payment;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::PriceOps::Hold;

my $UUID = qr/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i;

my $UNAVAILABLE = 'This payment cannot be taken right now. Nothing has been charged.';

# What is owed is read from the run's owed_payment, which the step before this
# one writes and the controller never accepts from a request: { offer_version_id,
# payment_plan, amount_cents, description, purpose }. The form is never read
# for any of it. The payment this step started is owed_payment_id, also
# server-owned. Nothing here knows what the payment is for: the next step does.
#
# Like the shared Payment step, the Stripe-touching branches return a promise.
method process ( $db, $form_data, $run = undef ) {
    $run //= $self->workflow($db)->latest_run($db);
    $db = $db->db if $db isa Registry::DAO;

    # Paid, whether the webhook settled it with nobody present or the person
    # came back first: hand the run on. Both arriving is harmless.
    return {} if $self->_paid( $db, $run );

    if ( defined( my $intent_id = $form_data->{payment_intent_id} ) ) {
        return $self->_returned( $db, $run, $intent_id );
    }

    if ( my $refusal = $self->hold_for_charge( $db, $run ) ) {
        return $self->_stay( errors => [$refusal] );
    }
    my $owed = $self->owed_payment( $db, $run );
    return $self->_stay( errors => $owed->{errors} ) if $owed->{errors};
    my $payment = $owed->{payment};

    my $user = Registry::DAO::User->find( $db, { id => $payment->user_id } );
    return $payment->create_payment_intent_async( $db, {
        description   => $payment->metadata->{description},
        receipt_email => $user ? $user->email : undef,
    } )->then(
        sub ($intent) {
            $self->_stay(
                payment_id       => $payment->id,
                client_secret    => $intent->{client_secret},
                stripe_account   => $payment->metadata->{stripe_account_id},
                show_stripe_form => 1 );
        },
        sub ($error) { $self->_stay( errors => ["Payment processing error: $error"] ) },
    );
}

# owed_payment($db, $run) -> { payment => Payment } | { errors => [...] }
#
# The pending payment for what the run owes: this run's own still-open row
# when there is one, otherwise a new row stamped with the offer version and
# the seller's platform terms (Payment->create). Refused, with no row written,
# for anything that would charge the wrong amount, nothing, or the wrong account.
method owed_payment ( $db, $run ) {
    $db = $db->db if $db isa Registry::DAO;
    my sub refuse ($why) { return { errors => [$why] } }

    my $owed = $run->data->{owed_payment};
    return refuse('Nothing is owed on this run.') unless ref $owed eq 'HASH';
    my ( $version, $plan, $amount ) = $owed->@{qw( offer_version_id payment_plan amount_cents )};
    return refuse('Nothing is owed on this run: it names no offer version.')
        unless defined $version && !ref $version && $version =~ $UUID;
    return refuse('Nothing is owed on this run: it names no payment plan.')
        unless defined $plan && !ref $plan && length $plan;
    # Whole cents above zero, never a $0 charge; eight digits is Stripe's ceiling.
    return refuse('The amount owed must be a whole number of cents above zero.')
        unless defined $amount && !ref $amount && $amount =~ /\A[1-9][0-9]{0,7}\z/;

    my $user_id = $run->data->{user_id};
    return refuse('Nobody is signed in to pay.')
        unless defined $user_id && !ref $user_id && $user_id =~ $UUID;

    # The seller is the tenant the run is in, and the charge is made on its own
    # account; there is no fallback to the platform's.
    my $slug = $run->data->{__tenant_slug};
    my $row  = defined $slug && !ref $slug
        ? $db->query( 'SELECT * FROM registry.tenants WHERE slug = ?', $slug )->hash
        : undef;
    unless ( $row && Registry::DAO::Tenant->new(%$row)->stripe_connect_ready ) {
        warn sprintf "one-time payment refused: tenant '%s' is not Stripe Connect ready\n",
            $slug // '(unknown)';
        return refuse($UNAVAILABLE);
    }

    # One of the version's own plans, published, in this schema.
    return refuse('The offer this payment is for cannot be sold.')
        unless $db->query( q{
            SELECT 1 FROM offer_version_payment_plans p
              JOIN offer_versions v ON v.id = p.offer_version_id
             WHERE v.id = ? AND p.id = ? AND v.published_at IS NOT NULL
        }, $version, $plan )->rows;

    # This run's open payment is reused, so a second submit sends the same
    # idempotency key and Stripe makes one intent. One that no longer matches
    # what is owed is refused rather than re-priced under the same key.
    # shortcut: a changed amount dead-ends the run; cancel and rotate as the
    # cart step does if a prior step ever re-prices an owed payment.
    if ( my $open = $self->_run_payment( $db, $run ) ) {
        if ( $open->status eq 'pending' || $open->status eq 'processing' ) {
            return refuse('What is owed changed after this payment was started.')
                unless _matches( $open, $owed );
            return { payment => $open };
        }
    }

    my $description = $owed->{description};
    my $purpose     = $owed->{purpose};
    my $payment = eval {
        Registry::DAO::Payment->create( $db, {
            user_id          => $user_id,
            amount_cents     => $amount,
            offer_version_id => $version,
            metadata         => {
                workflow_id     => $run->workflow_id,
                workflow_run_id => $run->id,
                tenant_slug     => $slug,
                payment_plan_id => $plan,
                description     => ( defined $description && !ref $description && length $description )
                    ? $description : 'Payment',
                ( defined $purpose && !ref $purpose ? ( purpose => $purpose ) : () ),
            },
        } );
    };
    unless ($payment) {
        # A seller with no platform entitlement dies in create, before any row.
        warn "one-time payment refused for run @{[ $run->id ]}: " . ( $@ =~ s/\s+\z//r ) . "\n";
        return refuse($UNAVAILABLE);
    }

    $run->update_data( $db, { owed_payment_id => $payment->id } );
    return { payment => $payment };
}

# hold_for_charge($db, $run) -> refusal | undef
#
# What is owed may be for seats a prior step holds (owed_payment.hold_id): the
# charge is taken only while that hold is live. A lapsed or gone hold is
# released and refused before anything is charged. When the charge starts
# (the run has no payment yet) a live hold is extended by its own length, once:
# never past placed_at + 2 x lifetime, so it does not lapse under a card check
# in flight and no number of posts holds the seats longer.
method hold_for_charge ( $db, $run ) {
    $db = $db->db if $db isa Registry::DAO;
    my $owed    = $run->data->{owed_payment};
    my $hold_id = ref $owed eq 'HASH' ? $owed->{hold_id} : undef;
    return undef unless defined $hold_id;
    my $lapsed = 'The seats held for this payment were let go. Nothing has been charged.';
    return $lapsed unless !ref $hold_id && $hold_id =~ $UUID;

    my $tx = $db->dbh->{AutoCommit} ? $db->begin : undef;
    # The run's row first, as the change steps lock it: whether a payment
    # started is read under it, never from a copy loaded before.
    my $started = $db->query( q{SELECT data->>'owed_payment_id' FROM workflow_runs WHERE id = ? FOR UPDATE},
        $run->id )->array->[0];
    my $live = Registry::PriceOps::Hold->live_sql('holds');
    my $hold = $db->query( "SELECT $live AS live FROM holds WHERE id = ? AND workflow_run_id = ? FOR UPDATE",
        $hold_id, $run->id )->hash;
    unless ( $hold && $hold->{live} ) {
        $db->query( q{UPDATE holds SET state = 'released' WHERE id = ? AND state = 'held'}, $hold_id ) if $hold;
        $tx->commit if $tx;
        return $hold ? 'The seats held for this payment lapsed. Nothing has been charged.' : $lapsed;
    }
    # Never past twice the lifetime it was placed with, however often this runs.
    $db->query( q{UPDATE holds SET expires_at = greatest(expires_at, placed_at + 2 * lifetime)
                   WHERE id = ? AND lifetime IS NOT NULL}, $hold_id )
        unless defined $started;
    $tx->commit if $tx;
    return undef;
}

# The person's return from Stripe. The intent must be the one stored on this
# run's payment, for its amount (Payment::_apply_intent).
method _returned ( $db, $run, $intent_id ) {
    my $payment = !ref $intent_id && $self->_run_payment( $db, $run )
        or return $self->_stay( errors => ['No payment was started here.'] );

    return $payment->process_payment_async( $db, $intent_id )->then( sub ($result) {
        return {} if $self->_paid( $db, $run );
        return $self->_stay( message => 'Payment is being processed. Please wait...' )
            if $result->{processing};
        return $self->_stay( errors => [ $result->{error} // 'The payment was not completed.' ] );
    } );
}

# Completed, by this run, for exactly what the run owes.
method _paid ( $db, $run ) {
    my $payment = $self->_run_payment( $db, $run ) or return 0;
    my $owed    = $run->data->{owed_payment};
    return ref $owed eq 'HASH' && $payment->status eq 'completed' && _matches( $payment, $owed );
}

sub _matches ( $payment, $owed ) {
    return ( $payment->amount_cents // '' ) eq ( $owed->{amount_cents} // "\0" )
        && ( $payment->offer_version_id // '' ) eq ( $owed->{offer_version_id} // "\0" )
        && ( $payment->metadata->{payment_plan_id} // '' ) eq ( $owed->{payment_plan} // "\0" );
}

# The payment this step started for this run, or undef. The id is bound into
# a WHERE clause, so only a plain UUID is looked up.
method _run_payment ( $db, $run ) {
    my $id = $run->data->{owed_payment_id};
    return undef unless defined $id && !ref $id && $id =~ $UUID;
    my $payment = Registry::DAO::Payment->find( $db, { id => $id } ) or return undef;
    return ( ( $payment->metadata // {} )->{workflow_run_id} // '' ) eq $run->id ? $payment : undef;
}

method _stay (%data) {
    my $errors = delete $data{errors};
    return {
        next_step => $self->id,
        ( $errors ? ( errors => $errors ) : () ),
        data => { step_data => \%data },
    };
}

}

1;
