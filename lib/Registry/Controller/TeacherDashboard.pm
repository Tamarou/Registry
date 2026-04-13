# ABOUTME: Controller for teacher-facing dashboard pages and attendance management
# ABOUTME: Route-level authentication is handled by under() guards in Registry.pm
use 5.42.0;
use Object::Pad;
use DateTime;

class Registry::Controller::TeacherDashboard :isa(Registry::Controller) {
    use Registry::DAO::Event;
    use Registry::DAO::Enrollment;
    use Registry::DAO::Attendance;
    use Registry::DAO::Location;
    use Registry::DAO::Project;

    method attendance {
        my $event_id = $self->param('event_id');
        my $dao = $self->app->dao;

        # Get event details
        my $event_obj = Registry::DAO::Event->find($dao, { id => $event_id });

        unless ($event_obj) {
            return $self->render(text => 'Event not found', status => 404);
        }

        # Serialize event to a hashref for the template, including
        # joined location and program names from related tables.
        my $db = $dao->db;
        my $location = $event_obj->location_id
            ? Registry::DAO::Location->find($db, { id => $event_obj->location_id })
            : undef;
        my $program = $event_obj->project_id
            ? Registry::DAO::Project->find($db, { id => $event_obj->project_id })
            : undef;

        my $event = {
            id            => $event_obj->id,
            time          => $event_obj->time,
            duration      => $event_obj->duration,
            metadata      => $event_obj->metadata || {},
            location_name => $location ? $location->name : undef,
            program_name  => $program ? $program->name : undef,
        };

        # Get enrolled students for this event
        my $students = Registry::DAO::Enrollment->get_students_for_event($db, $event_id, tenant => $self->stash('tenant'));

        # Get existing attendance records
        my $attendance = Registry::DAO::Attendance->get_event_attendance($db, $event_id, tenant => $self->stash('tenant'));

        # Create attendance lookup for template
        my %attendance_lookup = map { $_->{student_id} => $_->{status} } @$attendance;

        $self->render(
            template   => 'teacher/attendance',
            event      => $event,
            students   => $students,
            attendance => \%attendance_lookup,
        );
    }

    method mark_attendance {
        my $event_id = $self->param('event_id');
        my $attendance_data = $self->req->json;
        my $dao = $self->app->dao;

        unless ($attendance_data && ref $attendance_data eq 'HASH') {
            return $self->render(json => { error => 'Invalid attendance data' }, status => 400);
        }

        my $current_user = $self->stash('current_user');
        my $user_id      = $current_user ? $current_user->{id} : $self->session('user_id');

        try {
            my $db = $dao->db;
            my $tx = $db->begin;

            for my $student_id (keys %$attendance_data) {
                my $status = $attendance_data->{$student_id};
                next unless $status =~ /^(present|absent)$/;

                Registry::DAO::Attendance->mark_attendance(
                    $db,
                    $event_id,
                    $student_id,
                    $status,
                    $user_id
                );
            }

            $tx->commit;

            $self->render(json => {
                success => 1,
                message => 'Attendance recorded successfully',
                total_marked => scalar(keys %$attendance_data)
            });
        } catch ($error) {
            $self->render(json => {
                error => 'Failed to record attendance',
                details => $error
            }, status => 500);
        }
    }

    method dashboard {
        my $current_user = $self->stash('current_user');
        my $user_id      = $current_user ? $current_user->{id} : $self->session('user_id');
        my $dao = $self->app->dao;

        # Get today's events for this teacher - use class method
        my $today_events = Registry::DAO::Event->get_teacher_events_for_date(
            $dao->db,
            $user_id,
            DateTime->today->ymd,
            tenant => $self->stash('tenant')
        );

        # Get upcoming events (next 7 days) - use class method
        my $upcoming_events = Registry::DAO::Event->get_teacher_upcoming_events(
            $dao->db,
            $user_id,
            7,
            tenant => $self->stash('tenant')
        );

        $self->render(
            template        => 'teacher/dashboard',
            today_events    => $today_events,
            upcoming_events => $upcoming_events,
        );
    }
}

1;
