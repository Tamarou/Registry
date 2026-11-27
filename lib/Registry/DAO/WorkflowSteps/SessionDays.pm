# ABOUTME: session-setup's sessions step: each post adds one session to the run's program, a finite resource with its days.
# ABOUTME: Days are the chosen weekdays from the first day to the last; the run's sessions are listed, and continue moves on.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::SessionDays :isa(Registry::DAO::WorkflowStep) {
    use DateTime;
    use Registry::DAO::Project;
    use Registry::DAO::Resource;
    use Registry::DAO::WorkflowSteps::GenerateOccurrences;
    use Registry::DAO::WorkflowSteps::SessionProgram;

    # GenerateOccurrences' limit: a season at a time.
    my $MAX_DAYS = 366;

    sub _date ($text) {
        return undef unless $text =~ /\A([0-9]{4})-([0-9]{2})-([0-9]{2})\z/;
        return eval { DateTime->new( year => $1, month => $2, day => $3 ) };
    }

    method process ( $db, $form_data, $run = undef ) {
        if ( my $refused = Registry::DAO::WorkflowSteps::SessionProgram->refuse_non_admin( $db, $run ) ) {
            return $refused;
        }
        my $program = $run->data->{session_program};
        return { stay => 1, errors => ['Choose the program first'] } unless ref $program eq 'HASH';

        my %f = map { $_ => ( ref $form_data->{$_} ? '' : $form_data->{$_} // '' ) }
            qw( action name first_day last_day start minutes capacity waitlist offer_hold_hours teacher_id );

        if ( $f{action} eq 'continue' ) {
            return { stay => 1, errors => ['Add at least one session'] } unless ( $run->data->{sessions} // [] )->@*;
            return {};
        }
        # A run's start submits only the seeded user: show the form.
        return { stay => 1 } unless $f{action} eq 'add';

        my $weekdays = $form_data->{weekdays} // [];
        my @weekdays = ref $weekdays eq 'ARRAY' ? @$weekdays : ($weekdays);

        my @errors;
        my $name = $f{name} =~ s/\A\s+|\s+\z//gr;
        push @errors, 'Name the session' unless length $name;
        push @errors, 'Choose a teacher from your staff and administrators'
            unless grep { $_->{id} eq $f{teacher_id} } Registry::DAO::WorkflowSteps::GenerateOccurrences->teachers($db)->@*;
        push @errors, 'Choose at least one weekday'
            unless @weekdays && !grep { ref || !defined || !/\A[1-7]\z/ } @weekdays;
        push @errors, 'The start time is a local time like 09:00'
            unless $f{start} =~ /\A(?:[01][0-9]|2[0-3]):[0-5][0-9]\z/;
        push @errors, 'The length is a whole number of minutes from 1 to 1440'
            unless $f{minutes} =~ /\A[1-9][0-9]{0,3}\z/ && $f{minutes} <= 1440;
        # Nine digits at most, so every accepted number fits the integer column.
        push @errors, 'The capacity is a whole number of at least one' unless $f{capacity} =~ /\A[1-9][0-9]{0,8}\z/;
        if ( $f{waitlist} eq 'queue' ) {
            # The resources_waitlist_kind check allows 1 to 9999 hours.
            push @errors, 'A queue needs the hours a freed seat is held for the next child, from 1 to 9999'
                unless $f{offer_hold_hours} =~ /\A[1-9][0-9]{0,3}\z/;
        }
        elsif ( $f{waitlist} ne 'none' ) {
            push @errors, 'Choose no waitlist or a queue';
        }

        my ( $first, $last ) = map { _date($_) } @f{qw( first_day last_day )};
        my @days;
        if ( !$first || !$last ) {
            push @errors, 'The first and last days are dates like 2027-06-07';
        }
        elsif ( $last < $first ) {
            push @errors, 'The last day is before the first';
        }
        elsif ( ( my $span = $last->delta_days($first)->in_units('days') ) > $MAX_DAYS ) {
            push @errors, "A session spans at most $MAX_DAYS days; this one spans $span";
        }
        else {
            my %on = map { $_ => 1 } @weekdays;
            for ( my $day = $first->clone ; $day <= $last ; $day->add( days => 1 ) ) {
                push @days, $day->ymd if $on{ $day->day_of_week };
            }
            push @errors, 'None of the chosen weekdays falls between the first and last day' unless @days || !@weekdays;
        }
        return { stay => 1, errors => \@errors } if @errors;

        # The run's row is locked while the session is made and recorded, so
        # two posts at once each append theirs.
        my $tx = $db->dbh->{AutoCommit} ? $db->begin : undef;
        my $made = $db->query( q{SELECT data->'sessions' FROM workflow_runs WHERE id = ? FOR UPDATE}, $run->id )
            ->expand->array->[0] // [];
        # In list context it also returns the days a spring-forward gap moved,
        # which the admin is shown, as GenerateOccurrences reports them.
        my ( $session, $shifted ) = Registry::DAO::Resource->create_session( $db, {
            name       => $name,
            capacity   => 0 + $f{capacity},
            waitlist   => $f{waitlist} eq 'queue'
                ? { kind => 'queue', offer_hold_hours => 0 + $f{offer_hold_hours} }
                : { kind => 'none' },
            project_id => $program->{project_id},
            location_id => $program->{location_id},
            teacher_id => $f{teacher_id},
            days       => \@days,
            start      => $f{start},
            minutes    => 0 + $f{minutes},
        } );
        $run->update_data( $db, { sessions => [ @$made, $session->id ] } );
        $tx->commit if $tx;

        return { stay => 1, template_data => { shifted => $shifted } };
    }

    method prepare_template_data ( $db, $run, $params = {} ) {
        my $program = $run->data->{session_program} // {};
        my ($project) = $program->{project_id} ? Registry::DAO::Project->find( $db, { id => $program->{project_id} } ) : ();
        my @sessions = map {
            my ($session) = Registry::DAO::Resource->find( $db, { id => $_ } );
            my $days = $db->query( q{
                SELECT to_char(min(e.time AT TIME ZONE l.time_zone), 'YYYY-MM-DD') AS first_day,
                       to_char(max(e.time AT TIME ZONE l.time_zone), 'YYYY-MM-DD') AS last_day, count(*) AS days
                  FROM events e JOIN locations l ON l.id = e.location_id
                 WHERE e.session_resource_id = ?
            }, $_ )->hash;
            $session ? { name => $session->name, capacity => $session->capacity, waitlist => $session->waitlist, %$days } : ();
        } ( $run->data->{sessions} // [] )->@*;
        return {
            program_name => $project ? $project->name : '',
            teachers     => Registry::DAO::WorkflowSteps::GenerateOccurrences->teachers($db),
            session_list => \@sessions,
        };
    }
}

1;
