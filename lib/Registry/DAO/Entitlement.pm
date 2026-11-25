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
    field $terms_version :param :reader = undef;        # the /terms version its booker agreed to, set at insert

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

    # Accepts offer version $data->{offer_version_id} under its payment plan
    # $data->{payment_plan_id} for the one holder $data names, in effect from
    # starts_at (default now): the one way a schedule-type offer is accepted.
    # Throws Registry::DAO::Entitlement::Refused, creating nothing, when the
    # version is not published and current at this moment, does not offer the
    # plan, the plan is one-time (an entitlement follows its payment, not an
    # accept), the holder already has this offer in effect, or a tenant
    # holder already has platform terms for payment processing. Joins the
    # caller's transaction.
    sub accept ( $class, $db, $data ) {
        $db = $db->db if $db isa Registry::DAO;
        my %row = ( starts_at => 'now', %$data );
        my ( $version_id, $plan_id ) = @row{qw( offer_version_id payment_plan_id )};
        my $refuse = sub ($why) { Registry::DAO::Entitlement::Refused->throw("$why\n") };
        my $tx = $db->dbh->{AutoCommit} ? $db->begin : undef;

        # Locked: a supersede waits for this accept to commit, or this accept
        # waits for the supersede and then reads the version as retired.
        my ($offer_id) = @{ $db->query( q{
            SELECT offer_id FROM offer_versions
             WHERE id::text = ? AND published_at IS NOT NULL AND superseded_at IS NULL FOR SHARE
        }, $version_id // '' )->array // [] };
        $refuse->("Offer version $version_id is not on offer: it is unpublished or has been replaced.")
            unless $offer_id;

        my $kind = $db->select( 'offer_version_payment_plans', 'kind',
            { offer_version_id => $version_id, id => $plan_id // '' } )->array;
        $refuse->( sprintf "Offer version %s does not offer payment plan '%s'.", $version_id, $plan_id // '' )
            unless $kind;
        $refuse->("Payment plan '$plan_id' is one-time: it is accepted by paying for it.")
            if $kind->[0] eq 'one_time';

        # One phase of a schedule offer per holder at a time, as the exclusion
        # constraint has it; two accepts for one holder and offer take turns,
        # so the second reads the first and is refused here, not by it.
        my $holder = $row{holder_user_id} // $row{holder_family_member_id} // $row{holder_tenant_id};
        $db->query( 'SELECT pg_advisory_xact_lock(hashtextextended(?, 0))', "accept:$holder:$offer_id" );
        $refuse->('This holder already holds this offer in effect.')
            if $db->query( q{
                SELECT EXISTS (SELECT 1 FROM entitlements
                    WHERE coalesce(holder_user_id, holder_family_member_id, holder_tenant_id) = ?
                      AND offer_id = ? AND plan_kind <> 'one_time'
                      AND in_effect && tstzrange(?::timestamptz, ?::timestamptz, '[)'))
            }, $holder, $offer_id, @row{qw( starts_at ends_at )} )->array->[0];

        # A tenant's platform terms for payment processing, one at a time across
        # offers: platform-entitlement-one-in-effect's rule, asked under its lock
        # so the refusal is this message rather than its trigger's error.
        if ( my $tenant = $row{holder_tenant_id} ) {
            $db->query( 'SELECT pg_advisory_xact_lock(hashtextextended(?, 0))', "platform_entitlement:$tenant" );
            $refuse->('This tenant already holds platform terms in effect: they must end before it accepts another platform offer.')
                if $db->query( q{
                    SELECT EXISTS (SELECT 1 FROM offer_versions v
                                     JOIN resources r ON r.id = v.resource_id
                                         OR r.id IN (SELECT s.resource_id FROM offer_version_resources s
                                                     WHERE s.offer_version_id = v.id)
                                    WHERE v.id = ? AND r.name = 'payment processing')
                       AND EXISTS (SELECT 1 FROM entitlements e
                                     JOIN offer_versions v ON v.id = e.offer_version_id
                                     JOIN resources r ON r.id = v.resource_id
                                         OR r.id IN (SELECT s.resource_id FROM offer_version_resources s
                                                     WHERE s.offer_version_id = v.id)
                                    WHERE e.holder_tenant_id = ? AND e.state = 'active'
                                      AND r.name = 'payment processing'
                                      AND e.in_effect && tstzrange(?::timestamptz, ?::timestamptz, '[)'))
                }, $version_id, $tenant, @row{qw( starts_at ends_at )} )->array->[0];
        }

        my $entitlement = $class->create( $db, \%row );
        $tx->commit if $tx;
        return $entitlement;
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
            unless $version && $version->buys( $db, $resource_id );
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

    # May tenant $tenant_id run workflow $slug? Only when it holds, in effect
    # now, the run:$slug resource from the platform tenant registry, by a
    # single-resource or a set version. Exact name match, live rows; through
    # Tenant->holds, the one seam, so a right recorded in a tenant's own schema
    # grants nothing.
    sub may_run ( $class, $db, $tenant_id, $slug ) {
        return 0 unless defined $slug && !ref $slug && length $slug;
        require Registry::DAO::Tenant;
        return Registry::DAO::Tenant->holds( $db, $tenant_id, "run:$slug" );
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

    # Ends as `expired` each active entitlement whose stamped expiry policy is
    # end_of_occurrence and whose units are on an occurrence that has ended,
    # at that occurrence's end. Its units are read under its row lock, so a
    # change that moved it is followed and a concurrent sweep expires it once.
    # Returns the ids it expired.
    sub expire_ended_occurrences ( $class, $db ) {
        $db = $db->db if $db isa Registry::DAO;
        # shortcut: every active end_of_occurrence entitlement is read each run;
        # prefilter on its events' times if this grows slow.
        my $candidates = $db->query( q{
            SELECT e.id FROM entitlements e JOIN offer_versions v ON v.id = e.offer_version_id
             WHERE e.state = 'active' AND v.policies->'expiry'->>'kind' = 'end_of_occurrence'
        } )->arrays->flatten;

        my @expired;
        for my $id (@$candidates) {
            my $tx = $db->dbh->{AutoCommit} ? $db->begin : undef;
            next unless $db->query( q{SELECT 1 FROM entitlements WHERE id = ? AND state = 'active' FOR UPDATE},
                $id )->rows;
            my @ends = map { ( $_->occurrence_window($db) )[1] }
                grep { $_->event_id } map { scalar Registry::DAO::Resource->find( $db, { id => $_ } ) }
                $db->select( 'entitlement_units', 'DISTINCT resource_id', { entitlement_id => $id } )
                ->arrays->flatten->each;
            my ( $over, $ended ) = $db->query(
                'SELECT max(e) <= now(), max(e) FROM unnest(?::timestamptz[]) e', \@ends )->array->@*;
            next unless $over;
            scalar( $class->find( $db, { id => $id } ) )->end( $db, 'expired', 'occurrence ended', $ended );
            $tx->commit if $tx;
            push @expired, $id;
        }
        return \@expired;
    }

    # Records that it was used at occurrence $occurrence_id, marked by
    # $recorded_by. Use is optional attendance: nothing requires a use, and
    # recording one changes no state, units, period or money. Throws
    # Registry::DAO::Entitlement::Refused, recording nothing, unless it is in
    # effect now, its stamped use policy is optional attendance, and it holds
    # units of that occurrence. A second record of the pair keeps the first.
    method record_use ( $db, $occurrence_id, $recorded_by = undef ) {
        $db = $db->db if $db isa Registry::DAO;
        my $refuse = sub ($why) { Registry::DAO::Entitlement::Refused->throw("$why\n") };
        $refuse->('This booking is not in effect: it has ended or been refunded.')
            unless $self->is_in_effect($db);
        $refuse->("This booking's offer does not record attendance.")
            unless ( ( $self->offer_version($db)->policies->{use} // {} )->{kind} // '' ) eq 'optional_attendance';
        $refuse->('This booking holds no place in that occurrence.')
            unless $self->units( $db, $occurrence_id )->@*;
        $db->insert( 'entitlement_uses',
            { entitlement_id => $id, occurrence_id => $occurrence_id, recorded_by => $recorded_by },
            { on_conflict => undef } );
        return $self;
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

    # Records its part of a refund Stripe reported: $refund names amount_cents
    # and stripe_refund_id. It changes no state. The same refund id records
    # once per entitlement; one refund may be shared among several.
    method record_refund ( $db, $refund ) {
        $db = $db->db if $db isa Registry::DAO;
        $db->insert( 'entitlement_refunds', { %$refund, entitlement_id => $id },
            { on_conflict => undef } );
        return $self;
    }

    # Cents refunded against it so far by partial refunds.
    method refunded_cents ($db) {
        $db = $db->db if $db isa Registry::DAO;
        return $db->query( 'SELECT coalesce(sum(amount_cents), 0) FROM entitlement_refunds
                             WHERE entitlement_id = ?', $id )->array->[0];
    }

    # The version it was sold under, superseded or not.
    method offer_version ($db) {
        return scalar Registry::DAO::OfferVersion->find( $db, { id => $offer_version_id } );
    }

    # Where a change may move it: the occurrences its stamped version covers,
    # less the one it holds. 01a20416-6e27 filters these by time and room.
    method change_targets ($db) {
        $db = $db->db if $db isa Registry::DAO;
        my %own = map { $_ => 1 } $db->select( 'entitlement_units', 'resource_id',
            { entitlement_id => $id } )->arrays->flatten->each;
        return [ grep { !$own{ $_->id } } $self->offer_version($db)->covered_resources($db)->@* ];
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

# What accept refuses with: a message for the person accepting, never a database error.
package Registry::DAO::Entitlement::Refused { use Mojo::Base 'Mojo::Exception' }

1;
