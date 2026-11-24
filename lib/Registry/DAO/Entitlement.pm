# ABOUTME: A PriceOps entitlement: what a holder has after accepting an offer version under one of its plans.
# ABOUTME: The stamp (offer version and payment plan) is fixed at creation and enforced by the database.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::Entitlement :isa(Registry::DAO::Object) {
    use Registry::DAO::OfferVersion;

    field $id :param :reader;
    field $holder_user_id :param :reader = undef;             # a person
    field $holder_family_member_id :param :reader = undef;    # a child, held for by a payer
    field $holder_tenant_id :param :reader = undef;           # a tenant, in registry
    field $payer_user_id :param :reader = undef;              # set only when not the holder
    field $offer_version_id :param :reader;
    field $payment_plan_id :param :reader;    # the plan's id within its offer version
    field $in_effect :param :reader;          # tstzrange, half-open [start, end)
    field $created_at :param :reader;

    sub table { 'entitlements' }

    # $data names the holder, payer, stamp, and starts_at with an optional
    # ends_at; the period is stored half-open.
    sub create ( $class, $db, $data ) {
        my %row = %$data;
        my ( $starts_at, $ends_at ) = delete @row{qw( starts_at ends_at )};
        $row{in_effect} = \[ "tstzrange(?, ?, '[)')", $starts_at, $ends_at ];
        return $class->SUPER::create( $db, \%row );
    }

    # The version it was sold under, superseded or not.
    method offer_version ($db) {
        return scalar Registry::DAO::OfferVersion->find( $db, { id => $offer_version_id } );
    }

    # Entitlements whose period covers $t, narrowed by $filter.
    # shortcut: reads the period alone, as no state exists yet; 01a20448-1177
    # rewires this to the one in-effect predicate (period and active state).
    sub in_effect_at ( $class, $db, $t, $filter = {} ) {
        return $class->find( $db, { %$filter, in_effect => \[ '@> ?::timestamptz', $t ] } );
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
