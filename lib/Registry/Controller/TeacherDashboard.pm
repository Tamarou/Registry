use 5.40.2;
use experimental 'signatures';
use Object::Pad;
use DateTime;

class Registry::Controller::TeacherDashboard :isa(Registry::Controller) {
    
    method auth_check {
        # Basic auth check - in production this would verify teacher role
        my $user_id = $self->session('user_id');
        unless ($user_id) {
            return $self->redirect_to('/user-creation');
        }
        $self->stash(user_id => $user_id);
        $self->stash(tenant => 'test-tenant'); # For testing
        return 1;
    }
    
    method attendance {
        my $event_id = $self->param('event_id');
        my $dao = $self->app->dao;
        
        # Get event details
        my $event = Registry::DAO::Event->find($dao, { id => $event_id });
        
        unless ($event) {
            return $self->render(text => 'Event not found', status => 404);
        }
        
        # Get enrolled students for this event - use class method  
        my $students = Registry::DAO::Enrollment->get_students_for_event($dao->db, $event_id, tenant => $self->stash('tenant'));
        
        # Get existing attendance records - use class method
        my $attendance = Registry::DAO::Attendance->get_event_attendance($dao->db, $event_id, tenant => $self->stash('tenant'));
        
        # Create attendance lookup for template
        my %attendance_lookup = map { $_->{student_id} => $_->{status} } @$attendance;
        
        $self->render(
            template => 'teacher/attendance',
            event => $event,
            students => $students,
            attendance => \%attendance_lookup,
            layout => 'teacher'
        );
    }
    
    method mark_attendance {
        my $event_id = $self->param('event_id');
        my $attendance_data = $self->req->json;
        my $dao = $self->app->dao;
        
        unless ($attendance_data && ref $attendance_data eq 'HASH') {
            return $self->render(json => { error => 'Invalid attendance data' }, status => 400);
        }
        
        my $user_id = $self->stash('user_id') // $self->session('user_id');
        
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
        my $user_id = $self->stash('user_id') // $self->session('user_id');
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
            template => 'teacher/dashboard',
            today_events => $today_events,
            upcoming_events => $upcoming_events,
            layout => 'teacher'
        );
    }
}

1;