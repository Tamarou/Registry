# ABOUTME: in-studio-schedule's step: generate a class's occurrences from a weekly pattern in the location's zone.
# ABOUTME: Each slot is a published events row with its own finite resource of the class's seats; existing slots are skipped.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::GenerateOccurrences :isa(Registry::DAO::WorkflowStep) {
    use DateTime;
    use Registry::DAO::Location;
    use Registry::DAO::Resource;
    use Registry::DAO::Tenant;
    use Registry::DAO::WorkflowSteps::ClassBasics;

    my $UUID = qr/\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/i;
    my %WEEKDAY = ( monday => 1, tuesday => 2, wednesday => 3, thursday => 4, friday => 5, saturday => 6, sunday => 7 );

    # The design's limit: a season at a time, extended by running again.
    my $MAX_DAYS = 366;

    # This schema's tenant's staff and admins, who may teach an occurrence.
    sub teachers ( $class, $db ) {
        return $db->query( q{
            SELECT u.id, COALESCE(p.name, u.username) AS name
              FROM users u
              JOIN registry.tenant_users tu ON tu.user_id = u.id
              JOIN registry.tenants t ON t.id = tu.tenant_id AND t.slug = current_schema()
              LEFT JOIN user_profiles p ON p.user_id = u.id
             WHERE tu.role IN ('staff', 'admin')
             ORDER BY 2
        } )->hashes->to_array;
    }

    method process ( $db, $form_data, $run = undef ) {
        my $user   = $run && ref $run->data->{user} eq 'HASH' ? $run->data->{user} : {};
        my $tenant = $db->query('SELECT current_schema()')->array->[0];
        return { stay => 1, errors => ['Only an administrator of this tenant can schedule occurrences'] }
            unless ( Registry::DAO::Tenant->role_in( $db, $tenant, $user->{id} ) // '' ) eq 'admin';

        # A run's start submits only the seeded user: show the form.
        return { stay => 1 } unless exists $form_data->{class_project_id};

        my %f = map { $_ => ( ref $form_data->{$_} ? '' : $form_data->{$_} // '' ) }
            qw( class_project_id location_id teacher_id start_time duration first_date last_date );
        my $days = $form_data->{weekdays} // [];
        my @days = ref $days eq 'ARRAY' ? @$days : ($days);

        my @errors;
        my ($class) = $f{class_project_id} =~ $UUID
            && grep { $_->id eq $f{class_project_id} } Registry::DAO::WorkflowSteps::ClassBasics->classes($db);
        push @errors, 'Choose one of your classes' unless $class;

        # The form defaults to the class's own location.
        my $location_id = length $f{location_id} ? $f{location_id} : $class ? $class->metadata->{location_id} // '' : '';
        my ($location) = $location_id =~ $UUID ? Registry::DAO::Location->find( $db, { id => $location_id } ) : ();
        push @errors, 'Choose one of your locations' unless $location;

        push @errors, 'Choose a teacher from your staff and administrators'
            unless grep { $_->{id} eq $f{teacher_id} } __PACKAGE__->teachers($db)->@*;
        push @errors, 'Choose at least one weekday'
            unless @days && !grep { ref || !defined || !$WEEKDAY{$_} } @days;
        push @errors, 'The start time is a local time like 10:00'
            unless $f{start_time} =~ /\A(?:[01][0-9]|2[0-3]):[0-5][0-9]\z/;
        push @errors, 'The duration is a whole number of minutes from 1 to 1440'
            unless $f{duration} =~ /\A[1-9][0-9]{0,3}\z/ && $f{duration} <= 1440;

        my ( $first, $last ) = map { _date($_) } @f{qw( first_date last_date )};
        push @errors, 'The first and last dates are dates like 2027-01-02' unless $first && $last;
        if ( $first && $last ) {
            my $days_between = $last->delta_days($first)->in_units('days');
            if ( $last < $first ) {
                push @errors, 'The last date is before the first';
            }
            elsif ( $days_between > $MAX_DAYS ) {
                push @errors, "Schedule at most $MAX_DAYS days at a time; this range is $days_between days";
            }
        }
        return { stay => 1, errors => \@errors } if @errors;

        my %on = map { $WEEKDAY{$_} => 1 } @days;
        my %report = ( created => 0, skipped => 0, shifted => [] );

        my $tx = $db->dbh->{AutoCommit} ? $db->begin : undef;
        # Locked, so the seats every occurrence gets are the class's as of
        # this run, and concurrent runs for the class take turns. NO KEY, so
        # unrelated inserts that reference the class are not held up.
        my $locked = $db->query( 'SELECT seats_per_occurrence FROM projects WHERE id = ? FOR NO KEY UPDATE', $class->id )
            ->array;
        # Deleted since it was listed: $tx, if ours, rolls back as it goes.
        return { stay => 1, errors => ['Choose one of your classes'] } unless $locked;
        my $seats = $locked->[0];

        for ( my $day = $first->clone ; $day <= $last ; $day->add( days => 1 ) ) {
            next unless $on{ $day->day_of_week };
            my $local = $day->ymd . " $f{start_time}";
            my $slot  = $self->instant( $db, $local, $location->time_zone );
            push $report{shifted}->@*, { asked => $local, local_start => $slot->{local_start} } if $slot->{shifted};

            my $event_id = $db->query( q{
                INSERT INTO events (project_id, location_id, teacher_id, time, duration, capacity, status)
                VALUES (?, ?, ?, ?, ?, ?, 'published')
                ON CONFLICT (project_id, location_id, time) DO NOTHING
                RETURNING id
            }, $class->id, $location->id, $f{teacher_id}, $slot->{instant}, 0 + $f{duration}, $seats )->array;

            if ($event_id) {
                Registry::DAO::Resource->for_occurrence( $db, $event_id->[0] );
                $report{created}++;
            }
            else {
                $report{skipped}++;
            }
        }
        $tx->commit if $tx;

        return { schedule_report => \%report };
    }

    # The instant local wall time $local ('YYYY-MM-DD HH:MI') names in $zone,
    # by the design's DST rule, computed here rather than left to a library:
    # a time that occurs twice is the earlier instant; a time that does not
    # exist moves forward by the gap (read with the offset before it) and is
    # reported as shifted. Offsets a day either side bound the candidates.
    sub instant ( $class, $db, $local, $zone ) {
        return $db->query( q{
            SELECT instant, NOT (be OR ae) AS shifted,
                   to_char(instant AT TIME ZONE z, 'YYYY-MM-DD HH24:MI') AS local_start
              FROM (
                SELECT z, CASE WHEN be AND ae THEN least(b, a) WHEN ae THEN a ELSE b END AS instant, be, ae
                  FROM (
                    SELECT z, b, a, (b AT TIME ZONE z) = l AS be, (a AT TIME ZONE z) = l AS ae
                      FROM (
                        SELECT l, z,
                               (l - ((u - interval '1 day') AT TIME ZONE z - (u - interval '1 day') AT TIME ZONE 'UTC'))
                                   AT TIME ZONE 'UTC' AS b,
                               (l - ((u + interval '1 day') AT TIME ZONE z - (u + interval '1 day') AT TIME ZONE 'UTC'))
                                   AT TIME ZONE 'UTC' AS a
                          FROM (SELECT ?::timestamp AS l, ?::text AS z, ?::timestamp AT TIME ZONE 'UTC' AS u) given
                      ) candidates
                  ) checked
              ) chosen
        }, $local, $zone, $local )->hash;
    }

    sub _date ($text) {
        return undef unless $text =~ /\A([0-9]{4})-([0-9]{2})-([0-9]{2})\z/;
        return eval { DateTime->new( year => $1, month => $2, day => $3 ) };
    }

    method prepare_template_data ( $db, $run, $params = {} ) {
        return {
            classes   => [ Registry::DAO::WorkflowSteps::ClassBasics->classes($db) ],
            locations => Registry::DAO::Location->list($db),
            teachers  => __PACKAGE__->teachers($db),
            weekdays  => [ sort { $WEEKDAY{$a} <=> $WEEKDAY{$b} } keys %WEEKDAY ],
        };
    }
}

1;
