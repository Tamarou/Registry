# ABOUTME: A PriceOps entitlement: what a holder has after accepting an offer version under one of its plans.
# ABOUTME: The stamp (offer version and payment plan) is fixed at creation and enforced by the database.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::Entitlement :isa(Registry::DAO::Object) {
    field $id :param :reader;
    field $holder_user_id :param :reader = undef;             # a person
    field $holder_family_member_id :param :reader = undef;    # a child, held for by a payer
    field $payer_user_id :param :reader = undef;              # set only when not the holder
    field $offer_version_id :param :reader;
    field $payment_plan_id :param :reader;    # the plan's id within its offer version
    field $created_at :param :reader;

    sub table { 'entitlements' }

    my @HOLDER = qw( holder_user_id holder_family_member_id );

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
