# ABOUTME: session-checkout step: one charge for the whole cart, each child's first share summed, while every line's seat is held.
# ABOUTME: The row names no offer version (each line's is stamped on its entitlement); a cart with an instalment child saves the card.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::SessionCartPayment :isa(Registry::DAO::WorkflowSteps::OneTimePayment) {
    use Data::Dumper ();
    use Registry::DAO::OfferVersion;
    use Registry::PriceOps::Instalments qw( parts );
    use Registry::DAO::WorkflowSteps::Payment;

    my $UUID  = qr/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i;
    my $CENTS = qr/\A[1-9][0-9]{0,7}\z/;

    # owed_payment($db, $run) -> { payment => Payment } | { errors => [...] }
    #
    # owed_payment is HoldSessionSeats': { purpose, amount_cents, lines => [ {
    # family_member_id, resource_id, offer_version_id, payment_plan_id, kind,
    # share_cents, parts, hold_id } ] }. Every line is checked, and the shares
    # must sum to the amount, before a row is written. Several children may be
    # on several versions, so payments.offer_version_id is left NULL and the
    # lines, parts and due dates included, are kept in the row's metadata:
    # completion stamps each line's version on its entitlement, and the
    # instalment schedule is built from the line's parts.
    method owed_payment ( $db, $run ) {
        $db = $db->db if $db isa Registry::DAO;
        my sub refuse ($why) { return { errors => [$why] } }

        # Camp checkout stays closed in production until the milestone lands.
        if ( my $closed = Registry::DAO::WorkflowSteps::Payment->camp_checkout_refusal ) {
            return refuse($closed);
        }

        my $owed  = $run->data->{owed_payment};
        my $lines = ref $owed eq 'HASH' ? $owed->{lines} : undef;
        return refuse('Nothing is owed on this run.') unless ref $lines eq 'ARRAY' && @$lines;
        my $amount = $owed->{amount_cents};
        return refuse('The amount owed must be a whole number of cents above zero.')
            unless defined $amount && !ref $amount && $amount =~ $CENTS;

        my $sum = 0;
        for my $line (@$lines) {
            # Checked on copies: matching a number in place would store it as text.
            my ( $child, $session, $version, $plan, $kind, $share ) = ref $line eq 'HASH'
                ? $line->@{qw( family_member_id resource_id offer_version_id payment_plan_id kind share_cents )} : ();
            return refuse('A line in this cart cannot be charged.')
                unless !grep( { !_plain($_) || !/$UUID/ } $child, $session, $version )
                && _plain($plan) && _plain($kind) && _plain($share) && $share =~ $CENTS;
            $sum += $share;
        }
        return refuse('The shares in this cart do not add up to what is owed.') unless $sum == $amount;

        if ( my $why = $self->payer_and_seller_refusal( $db, $run ) ) { return refuse($why) }

        # Each line's plan is one of its version's own, of the kind it says,
        # published, and its share (and an instalment line's parts) is what
        # that price and plan make: the hold step is not taken on trust.
        for my $line (@$lines) {
            return refuse('A price in this cart cannot be sold.') unless $self->line_is_priced( $db, $line );
        }

        return $self->open_or_create_payment( $db, $run, {
            amount_cents     => $amount,
            offer_version_id => undef,
            metadata         => { lines => $lines, description => 'Session booking' },
        } );
    }

    # line_is_priced($db, $line) -> bool
    #
    # A one-time line's share is its version's price; an instalment line's
    # parts are Instalments::parts of that price and plan from its first due
    # date, and its share is the first part.
    method line_is_priced ( $db, $line ) {
        my $version = Registry::DAO::OfferVersion->find( $db, { id => $line->{offer_version_id} } );
        return 0 unless $version && defined $version->published_at;
        my ($plan) = grep { $_->{id} eq $line->{payment_plan_id} && $_->{kind} eq $line->{kind} }
            $version->payment_plans($db)->@*;
        return 0 unless $plan;
        return $line->{share_cents} == $version->price_cents && !defined $line->{parts}
            if $plan->{kind} eq 'one_time';
        return 0 unless $plan->{kind} eq 'instalments';
        my $parts = $line->{parts};
        return 0 unless ref $parts eq 'ARRAY' && @$parts && ref $parts->[0] eq 'HASH';
        my $first = $parts->[0]{due_date};
        return 0 unless _plain($first) && $first =~ /\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/a;
        my $want = eval { parts( $version->price_cents, $plan, $first ) } or return 0;
        return $line->{share_cents} == $want->[0]{amount_cents} && _canonical($parts) eq _canonical($want);
    }

    # Every line's seat is held while the cart is charged.
    method held_for ($owed) {
        my $lines = $owed->{lines};
        return ref $lines eq 'ARRAY' ? map { ref $_ eq 'HASH' ? $_->{hold_id} : undef } @$lines : ();
    }

    # The started payment is for exactly this cart: its amount and its lines.
    method _matches ( $payment, $owed ) {
        return ( $payment->amount_cents // '' ) eq ( $owed->{amount_cents} // "\0" )
            && !defined $payment->offer_version_id
            && _canonical( $payment->metadata->{lines} ) eq _canonical( $owed->{lines} );
    }

    # Sorted and blind to whether jsonb handed a number back as one.
    sub _canonical ($data) {
        local ( $Data::Dumper::Sortkeys, $Data::Dumper::Indent, $Data::Dumper::Terse ) = ( 1, 0, 1 );
        return Data::Dumper::Dumper($data);
    }

    sub _plain ($value) { defined $value && !ref $value && length $value }
}

1;
