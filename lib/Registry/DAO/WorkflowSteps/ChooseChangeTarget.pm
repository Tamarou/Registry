# ABOUTME: entitlement-change step: checks a change against the entitlement's stamped policy and lists its targets.
# ABOUTME: Targets are the other occurrences its sold-under offer version covers that are on sale and have room.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::ChooseChangeTarget :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Entitlement;
    use Registry::DAO::Resource;
    use Registry::DAO::WorkflowSteps::GenerateOccurrences;

    method process ( $db, $form_data, $run = undef ) {
        my $id = $form_data->{entitlement_id};
        my $entitlement = defined $id && !ref $id && Registry::DAO::Entitlement->find( $db, { id => $id } );
        return { stay => 1, errors => ['Choose a booking to change'] } unless $entitlement;
        if ( my $refusal = __PACKAGE__->stranger( $entitlement, $run && $run->data->{user} )
            // __PACKAGE__->refusal( $db, $entitlement ) ) {
            return { stay => 1, errors => [$refusal] };
        }
        return {
            change_entitlement_id => $entitlement->id,
            change_targets        => [ map { { id => $_->id, name => $_->name } }
                __PACKAGE__->targets( $db, $entitlement )->@* ],
        };
    }

    # The signed-in person's bookings that are in effect, to choose from.
    method prepare_template_data ( $db, $run, $params = {} ) {
        my $user_id = ( $run->data->{user} // {} )->{id} or return { bookings => [] };
        my $current = Registry::DAO::Entitlement->in_effect_sql( 'e', 'tstzrange(now(), NULL)' );
        return { bookings => $db->query( qq{
            SELECT DISTINCT e.id, r.name FROM entitlements e
              JOIN entitlement_units u ON u.entitlement_id = e.id
              JOIN resources r ON r.id = u.resource_id
             WHERE $current AND ( e.holder_user_id = ? OR e.payer_user_id = ? )
             ORDER BY r.name
        }, $user_id, $user_id )->hashes->to_array };
    }

    # Why $user (the run's server-owned user) may not act on $entitlement, or
    # nothing: it is theirs when they hold or paid for it, and a tenant's
    # admin or staff acts for its holder. Asked again at hold and at charge,
    # so another person posting to the run's URLs gets no further. $verb
    # names the act in the refusal (entitlement-refund asks it too).
    sub stranger ( $class, $entitlement, $user, $verb = 'change' ) {
        my $id = ref $user eq 'HASH' ? $user->{id} // '' : '';
        return "Sign in to $verb a booking" unless length $id;
        return undef if grep { ( $_ // '' ) eq $id } $entitlement->holder_user_id, $entitlement->payer_user_id;
        return undef if ( $user->{role} // '' ) =~ /\A(?:admin|staff)\z/;
        return "That booking is not yours to $verb";
    }

    # Why $user may not run a change of $entitlement that charges $fee_cents,
    # or nothing. shortcut: who pays a change fee when staff or an admin start
    # the change for the booker is an open perigrin decision; until he rules,
    # only the booker (holder or payer) may run a change that charges a fee.
    # Asked before the hold is placed and again at the charge.
    sub fee_refusal ( $class, $entitlement, $user, $fee_cents ) {
        return undef unless $fee_cents;
        my $id = ref $user eq 'HASH' ? $user->{id} // '' : '';
        return undef if grep { ( $_ // '' ) eq $id } $entitlement->holder_user_id, $entitlement->payer_user_id;
        return 'This change has a fee, so the booker must start it from their booking.';
    }

    # Why $entitlement may not change at $at (default the clock) under the
    # change policy it was sold under (its stamped version, never the current
    # one), or nothing. The cutoff is its occurrence's local start less
    # window_hours on the wall clock of the location's zone, read back to an
    # instant by the occurrence-generation DST rule. The boundary is inclusive
    # (ADR 005 8b): at exactly the cutoff, a change is still allowed.
    sub refusal ( $class, $db, $entitlement, $at = undef ) {
        my $current = Registry::DAO::Entitlement->in_effect_sql( 'e', 'tstzrange(now(), NULL)' );
        return 'This booking has ended and cannot be changed'
            unless $db->query( "SELECT $current FROM entitlements e WHERE e.id = ?", $entitlement->id )->array->[0];
        my $policy = $entitlement->offer_version($db)->policies->{change} // {};
        return "This booking's offer says it cannot be changed" unless ( $policy->{kind} // '' ) eq 'window';
        my ($resource_id) = $db->select( 'entitlement_units', 'resource_id',
            { entitlement_id => $entitlement->id } )->arrays->flatten->each;
        my $local = $db->query( q{
            SELECT (e.time AT TIME ZONE l.time_zone) - make_interval(hours => ?) AS wall, l.time_zone
              FROM resources r JOIN events e ON e.id = r.event_id JOIN locations l ON l.id = e.location_id
             WHERE r.id = ?
        }, $policy->{window_hours}, $resource_id )->hash;
        my $cutoff = Registry::DAO::WorkflowSteps::GenerateOccurrences->instant( $db, $local->@{qw( wall time_zone )} )
            ->{instant};
        return sprintf 'Changes close %d hours before the class starts', $policy->{window_hours}
            unless $db->query( 'SELECT coalesce(?::timestamptz, clock_timestamp()) <= ?::timestamptz', $at, $cutoff )
                ->array->[0];
        return;
    }

    # The occurrences $entitlement may move to now: its change targets that
    # are on sale (published and still to start, as a booking asks) and have
    # room for every seat it holds.
    sub targets ( $class, $db, $entitlement ) {
        my $seats = $class->seats( $db, $entitlement );
        return [ grep { $_->on_sale($db) && $_->free_units($db) >= $seats }
                $entitlement->change_targets($db)->@* ];
    }

    sub seats ( $class, $db, $entitlement ) {
        return $db->select( 'entitlement_units', 'count(*)', { entitlement_id => $entitlement->id } )
            ->array->[0];
    }
}

1;
