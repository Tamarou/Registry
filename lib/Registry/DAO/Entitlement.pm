# ABOUTME: A PriceOps entitlement: what a holder has after accepting an offer version under one of its plans.
# ABOUTME: The stamp (offer version and payment plan) is fixed at creation and enforced by the database.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::Entitlement :isa(Registry::DAO::Object) {
    use Registry::DAO::OfferVersion;
    use Registry::DAO::Resource;
    use Carp qw( croak );

    field $id :param :reader;
    field $holder_user_id :param :reader = undef;             # a person
    field $holder_family_member_id :param :reader = undef;    # a child, held for by a payer
    field $holder_tenant_id :param :reader = undef;           # a tenant, in registry
    field $payer_user_id :param :reader = undef;              # set only when not the holder
    field $offer_version_id :param :reader;
    field $payment_plan_id :param :reader;    # the plan's id within its offer version
    field $in_effect :param :reader;          # tstzrange, half-open [start, end)
    field $created_at :param :reader;
    field $state :param :reader;                 # see LIFECYCLE
    field $ended_at :param :reader = undef;      # set once, by end()
    field $ended_reason :param :reader = undef;  # the Stripe refund or dispute id where there is one
    field $payment_id :param :reader = undef;           # the payment that created it, set at insert
    field $payment_share_cents :param :reader = undef;  # its share of that payment

    sub table { 'entitlements' }

=head1 LIFECYCLE

C<state> is C<active> until end() moves it, once, to one ended state:
C<expired> (its occurrence ended), C<refunded> (a full refund reported by
Stripe) or C<dispute_lost> (a lost dispute). Ending records C<ended_at> and
C<ended_reason> and closes the period at C<ended_at>. In effect at T means
active and the period covers T (in_effect_sql).

=cut

    # $data names the holder, payer, stamp, and starts_at with an optional
    # ends_at; the period is stored half-open. A paid entitlement also names
    # payment_id and payment_share_cents, which nothing changes afterwards.
    sub create ( $class, $db, $data ) {
        my %row = %$data;
        my ( $starts_at, $ends_at ) = delete @row{qw( starts_at ends_at )};
        $row{in_effect} = \[ "tstzrange(?, ?, '[)')", $starts_at, $ends_at ];
        return $class->SUPER::create( $db, \%row );
    }

    # Grants $data's entitlement holding units of $data->{resource_id}: either
    # `units` (a count, lowest free numbers first) or `unit_numbers` (named).
    # All or nothing, under the resource's lock.
    sub grant ( $class, $db, $data ) {
        $db = $db->db if $db isa Registry::DAO;
        my %row = %$data;
        my ( $resource_id, $count, $numbers ) = delete @row{qw( resource_id units unit_numbers )};

        my $tx       = $db->dbh->{AutoCommit} ? $db->begin : undef;
        my $resource = Registry::DAO::Resource->locked( $db, $resource_id );
        my $version  = Registry::DAO::OfferVersion->find( $db, { id => $row{offer_version_id} } );
        croak "offer version $row{offer_version_id} does not buy resource $resource_id"
            unless $version && $version->buys($resource_id);
        $resource->claim( $db, $numbers ? scalar @$numbers : $count );

        my %held = map { $_ => 1 } $resource->held_units($db)->@*;
        $numbers //= [ ( grep { !$held{$_} } 1 .. $resource->capacity )[ 0 .. $count - 1 ] ];
        for my $n (@$numbers) {
            croak sprintf 'unit %s of %s (%s) is not free', $n, $resource->name, $resource_id
                if $n !~ /\A[1-9][0-9]*\z/ || $n > $resource->capacity || $held{$n}++;
        }

        my $entitlement = $class->create( $db, \%row );
        $db->insert( 'entitlement_units',
            { entitlement_id => $entitlement->id, resource_id => $resource_id, unit => $_ } )
            for @$numbers;
        $tx->commit if $tx;
        return $entitlement;
    }

    # The unit numbers this entitlement holds of $resource_id.
    method units ( $db, $resource_id ) {
        $db = $db->db if $db isa Registry::DAO;
        return $db->select( 'entitlement_units', 'unit',
            { entitlement_id => $id, resource_id => $resource_id }, 'unit' )->arrays->flatten->to_array;
    }

    # Pillar 4: does $holder_id hold a unit of $resource_id in effect now?
    sub holds_unit_of ( $class, $db, $holder_id, $resource_id ) {
        $db = $db->db if $db isa Registry::DAO;
        my $in_effect = $class->in_effect_sql( 'e', q{tstzrange(now(), now(), '[]')} );
        return $db->query( qq{
            SELECT EXISTS (
                SELECT 1 FROM entitlement_units u JOIN entitlements e ON e.id = u.entitlement_id
                 WHERE u.resource_id = ? AND $in_effect
                   AND ? IN (e.holder_user_id, e.holder_family_member_id, e.holder_tenant_id))
        }, $resource_id, $holder_id )->array->[0];
    }

    # The one in-effect rule, as SQL over entitlement row $e (an alias or table
    # name): it is active and its period meets $when, a tstzrange expression.
    # A point T is tstzrange(T, T, '[]').
    sub in_effect_sql ( $class, $e, $when ) {
        return "($e.state = 'active' AND $e.in_effect && $when)";
    }

    # Is it in effect at $t (default now)?
    method is_in_effect ( $db, $t = undef ) {
        $db = $db->db if $db isa Registry::DAO;
        my $sql = __PACKAGE__->in_effect_sql( 'e',
            q{tstzrange(coalesce(?::timestamptz, now()), coalesce(?::timestamptz, now()), '[]')} );
        return $db->query( "SELECT $sql FROM entitlements e WHERE e.id = ?", $t, $t, $id )->array->[0];
    }

    # The one lifecycle move: ends it as $to_state for $reason at $at (default
    # now), closing its period there in the same UPDATE. The database refuses
    # any move out of an ended state.
    method end ( $db, $to_state, $reason, $at = undef ) {
        $db = $db->db if $db isa Registry::DAO;
        my $row = $db->query( q{
            UPDATE entitlements
               SET state = ?, ended_reason = ?, ended_at = coalesce(?::timestamptz, now()),
                   in_effect = in_effect * tstzrange(NULL, coalesce(?::timestamptz, now()))
             WHERE id = ? RETURNING *
        }, $to_state, $reason, $at, $at, $id )->expand->hash;
        return __PACKAGE__->new(%$row);
    }

    # Entitlements $payment_id created: what its refunds and disputes match.
    sub created_by_payment ( $class, $db, $payment_id ) {
        return $class->find( $db, { payment_id => $payment_id } );
    }

    # The payment that created it (its share is payment_share_cents); undef
    # when none did.
    method payment ($db) {
        return undef unless $payment_id;
        require Registry::DAO::Payment;
        return scalar Registry::DAO::Payment->find( $db, { id => $payment_id } );
    }

    # The version it was sold under, superseded or not.
    method offer_version ($db) {
        return scalar Registry::DAO::OfferVersion->find( $db, { id => $offer_version_id } );
    }

    # Entitlements in effect at $t, narrowed by $filter.
    sub in_effect_at ( $class, $db, $t, $filter = {} ) {
        my $in_effect = $class->in_effect_sql( 'entitlements',
            q{tstzrange(?::timestamptz, ?::timestamptz, '[]')} );
        return $class->find( $db, { %$filter, -and => [ \[ $in_effect, $t, $t ] ] } );
    }

    my @HOLDER = qw( holder_user_id holder_family_member_id holder_tenant_id );

    # Entitlements held by $holder_id, whichever kind of holder it is.
    sub held_by ( $class, $db, $holder_id ) {
        return $class->find( $db, { -or => [ map { { $_ => $holder_id } } @HOLDER ] } );
    }

    # Entitlements $user_id paid for: as the named payer, or as a holder who
    # paid for themselves.
    sub paid_by ( $class, $db, $user_id ) {
        return $class->find( $db, { -or => [
            { payer_user_id => $user_id },
            { payer_user_id => undef, holder_user_id => $user_id },
        ] } );
    }
}

1;
