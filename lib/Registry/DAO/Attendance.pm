use 5.40.2;
use utf8;
use experimental qw(try);
use Object::Pad;

class Registry::DAO::Attendance :isa(Registry::DAO::Object) {
    use Carp qw( croak );
    
    field $id :param :reader;
    field $event_id :param :reader;
    field $student_id :param :reader;
    field $family_member_id :param :reader;
    field $status :param :reader;
    field $marked_at :param :reader;
    field $marked_by :param :reader;
    field $notes :param :reader = '';
    field $created_at :param :reader;
    field $updated_at :param :reader;
    
    use constant table => 'attendance_records';
    
    BUILD {
        # Validate status
        unless ($status && $status =~ /^(present|absent)$/) {
            croak "Invalid attendance status: must be 'present' or 'absent'";
        }
    }
    
    sub create ($class, $db, $data) {
        # Validate required fields
        for my $field (qw(event_id student_id status marked_by)) {
            croak "Missing required field: $field" unless $data->{$field};
        }
        
        # Set marked_at if not provided
        $data->{marked_at} //= time();
        
        $class->SUPER::create($db, $data);
    }
    
    # Mark attendance for a student in an event
    sub mark_attendance ($class, $db, $event_id, $student_id, $status, $marked_by, $notes = undef) {
        # Check if attendance already exists
        my $existing = $class->find($db, { 
            event_id => $event_id, 
            student_id => $student_id 
        });
        
        if ($existing) {
            # Update existing record
            return $existing->update($db, {
                status => $status,
                marked_at => time(),
                marked_by => $marked_by,
                defined $notes ? (notes => $notes) : ()
            });
        }
        else {
            # Create new record
            return $class->create($db, {
                event_id => $event_id,
                student_id => $student_id,
                status => $status,
                marked_by => $marked_by,
                defined $notes ? (notes => $notes) : ()
            });
        }
    }
    
    # Get attendance records for an event
    sub get_event_attendance ($class, $db, $event_id, %opts) {
        my $results = $db->select(
            $class->table, 
            undef, 
            { event_id => $event_id },
            { -asc => 'student_id' }
        )->hashes;
        
        return $results->to_array;
    }
    
    # Get attendance records for a student
    sub get_student_attendance ($class, $db, $student_id, $options = {}) {
        my $where = { student_id => $student_id };
        
        # Add date range filter if provided
        if ($options->{start_date} || $options->{end_date}) {
            $where->{marked_at} = {};
            $where->{marked_at}{'>='} = $options->{start_date} if $options->{start_date};
            $where->{marked_at}{'<='} = $options->{end_date} if $options->{end_date};
        }
        
        my $results = $db->select(
            $class->table,
            undef,
            $where,
            { -desc => 'marked_at' }
        )->hashes;
        
        return [ map { $class->new(%$_) } @$results ];
    }
    
    # Get attendance summary for an event
    sub get_event_summary ($class, $db, $event_id) {
        my $sql = q{
            SELECT 
                COUNT(*) as total,
                COUNT(CASE WHEN status = 'present' THEN 1 END) as present,
                COUNT(CASE WHEN status = 'absent' THEN 1 END) as absent
            FROM attendance_records
            WHERE event_id = ?
        };
        
        my $result = $db->query($sql, $event_id)->hash;
        return {
            total => $result->{total} || 0,
            present => $result->{present} || 0,
            absent => $result->{absent} || 0,
            attendance_rate => $result->{total} ? 
                sprintf("%.1f%%", ($result->{present} / $result->{total}) * 100) : 
                "0.0%"
        };
    }
    
    # Bulk mark attendance for multiple students
    sub mark_bulk_attendance ($class, $db, $event_id, $attendance_data, $marked_by) {
        my @results;
        
        # Use a transaction for bulk operations
        my $tx = $db->begin;
        
        try {
            for my $record (@$attendance_data) {
                push @results, $class->mark_attendance(
                    $db,
                    $event_id,
                    $record->{student_id},
                    $record->{status},
                    $marked_by,
                    $record->{notes}
                );
            }
            $tx->commit;
        }
        catch ($e) {
            $tx->rollback;
            croak "Failed to mark bulk attendance: $e";
        }
        
        return \@results;
    }
    
    # Get related objects
    method event ($db) {
        require Registry::DAO::Event;
        Registry::DAO::Event->find($db, { id => $event_id });
    }
    
    method student ($db) {
        require Registry::DAO;
        Registry::DAO::User->find($db, { id => $student_id });
    }
    
    method marked_by_user ($db) {
        require Registry::DAO;
        Registry::DAO::User->find($db, { id => $marked_by });
    }
    
    method family_member ($db) {
        return unless $family_member_id;
        require Registry::DAO::Family;
        Registry::DAO::FamilyMember->find($db, { id => $family_member_id });
    }
    
    # Helper methods
    method is_present { $status eq 'present' }
    method is_absent { $status eq 'absent' }
    
    # Check if attendance was marked recently (within last hour by default)
    method is_recent ($threshold_seconds = 3600) {
        return (time() - $marked_at) < $threshold_seconds;
    }
}