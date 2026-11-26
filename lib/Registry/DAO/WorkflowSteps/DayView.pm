# ABOUTME: in-studio-day-view's one step: a studio-local day's occurrences at one location, seats held and bookings.
# ABOUTME: Its only write is RecordEntitlementUse's "present" mark; a malformed day or location is a 400.
use 5.42.0;
use utf8;

use Object::Pad;

require Registry::DAO::WorkflowSteps::RecordEntitlementUse;

class Registry::DAO::WorkflowSteps::DayView :isa(Registry::DAO::WorkflowSteps::RecordEntitlementUse) {
    use DateTime;
    use Mojo::URL;
    use Registry::DAO::Entitlement;
    use Registry::DAO::Resource;

    # Viewing submits no booking: stay. Marking one present is the parent's
    # write; once it is recorded, back to the same day.
    method process ( $db, $form_data, $run = undef ) {
        return { stay => 1 } unless exists $form_data->{entitlement_id};
        my $result = $self->SUPER::process( $db, $form_data, $run );
        return $result if $result->{errors};
        my %query = map { defined $form_data->{$_} && !ref $form_data->{$_} ? ( $_ => $form_data->{$_} ) : () }
            qw( day location_id );
        return { redirect => Mojo::URL->new('/in-studio-day-view')->query(%query)->to_string };
    }

    method prepare_template_data ( $db, $run, $params = {} ) {
        my $locations = $db->select( 'locations', [qw( id name time_zone )], undef, { -asc => 'name' } )
            ->hashes->to_array;
        my %page = ( locations => $locations, occurrences => [] );
        my $refuse = sub ($why) { return { %page, status => 400, errors => [$why] } };

        my ( $location_id, $day ) = map { $_ // '' } $params->@{qw( location_id day )};
        if ( length $day ) {
            my ( $y, $m, $d ) = ref $day ? () : $day =~ /\A(\d{4})-(\d\d)-(\d\d)\z/a;
            return $refuse->('Give the day as a real date, YYYY-MM-DD')
                unless $y && eval { DateTime->new( year => $y, month => $m, day => $d ); 1 };
        }
        return $refuse->('Choose one of the listed locations') if ref $location_id;
        my ($location) = length $location_id
            ? grep { $_->{id} eq $location_id } @$locations
            : @$locations == 1 ? @$locations : ();
        return $refuse->('Choose one of the listed locations') if length $location_id && !$location;
        return \%page unless $location;
        $page{location} = $location;

        $day = $db->query( q{SELECT to_char(now() AT TIME ZONE ?, 'YYYY-MM-DD')}, $location->{time_zone} )
            ->array->[0] unless length $day;
        $page{day} = $day;

        my $in_effect = Registry::DAO::Entitlement->in_effect_sql( 'e', 'tstzrange(now(), NULL)' );
        for my $o ( $db->query( q{
            SELECT r.id, p.name AS class, to_char(e.time AT TIME ZONE l.time_zone, 'HH24:MI') AS start
              FROM resources r
              JOIN events e ON e.id = r.event_id
              JOIN locations l ON l.id = e.location_id
              JOIN projects p ON p.id = e.project_id
             WHERE l.id = ? AND (e.time AT TIME ZONE l.time_zone)::date = ?::date
             ORDER BY e.time
        }, $location->{id}, $day )->hashes->each ) {
            my $resource = Registry::DAO::Resource->find( $db, { id => $o->{id} } );
            $o->{capacity} = $resource->capacity;
            $o->{held}     = $resource->capacity - $resource->free_units($db);
            $o->{bookings} = $db->query( qq{
                SELECT e.id, coalesce(up.name, u.username) AS booker, count(*) AS seats,
                       count(*) / ov.units_per_acceptance AS count,
                       EXISTS (SELECT 1 FROM entitlement_uses x
                                WHERE x.entitlement_id = e.id AND x.occurrence_id = eu.resource_id) AS present
                  FROM entitlement_units eu
                  JOIN entitlements e ON e.id = eu.entitlement_id
                  JOIN offer_versions ov ON ov.id = e.offer_version_id
                  LEFT JOIN users u ON u.id = e.holder_user_id
                  LEFT JOIN user_profiles up ON up.user_id = u.id
                 WHERE eu.resource_id = ? AND $in_effect
                 GROUP BY e.id, eu.resource_id, up.name, u.username, ov.units_per_acceptance
                 ORDER BY booker
            }, $o->{id} )->hashes->to_array;
            push $page{occurrences}->@*, $o;
        }
        return \%page;
    }
}

1;
