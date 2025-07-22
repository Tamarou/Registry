use 5.40.2;
use Object::Pad;

class Registry::DAO::FamilyMember :isa(Registry::DAO::Object) {
    use Carp qw( croak );
    use Mojo::JSON qw( decode_json encode_json );
    use experimental qw(try);
    
    field $id :param :reader;
    field $family_id :param :reader;
    field $child_name :param :reader;
    field $birth_date :param :reader;
    field $grade :param :reader;
    field $medical_info :param :reader = {};
    field $emergency_contact :param :reader = {};
    field $notes :param :reader = '';
    field $created_at :param :reader;
    field $updated_at :param :reader;
    
    sub table { 'family_members' }
    
    ADJUST {
        # Decode JSON fields if they're strings
        for my $field ($medical_info, $emergency_contact) {
            if (defined $field && !ref $field) {
                try {
                    $field = decode_json($field);
                }
                catch ($e) {
                    croak "Failed to decode JSON: $e";
                }
            }
        }
    }
    
    sub create ($class, $db, $data) {
        # Validate required fields
        for my $field (qw(family_id child_name birth_date)) {
            croak "Missing required field: $field" unless $data->{$field};
        }
        
        # Encode JSON fields
        for my $field (qw(medical_info emergency_contact)) {
            if (exists $data->{$field} && ref $data->{$field} eq 'HASH') {
                $data->{$field} = { -json => $data->{$field} };
            }
        }
        
        # Set defaults
        $data->{medical_info} //= { -json => {} };
        $data->{emergency_contact} //= { -json => {} };
        
        $class->SUPER::create($db, $data);
    }
    
    method update ($db, $data) {
        # Encode JSON fields
        for my $field (qw(medical_info emergency_contact)) {
            if (exists $data->{$field} && ref $data->{$field} eq 'HASH') {
                $data->{$field} = { -json => $data->{$field} };
            }
        }
        
        $self->SUPER::update($db, $data);
    }
    
    # Calculate age from birth date
    method age ($as_of_date = time()) {
        return unless $birth_date;
        
        # Parse dates (simplified - in production use DateTime)
        my ($birth_year, $birth_month, $birth_day) = split /-/, $birth_date;
        my ($year, $month, $day) = (localtime($as_of_date))[5,4,3];
        $year += 1900;
        $month += 1;
        
        my $age = $year - $birth_year;
        $age-- if $month < $birth_month || ($month == $birth_month && $day < $birth_day);
        
        return $age;
    }
    
    # Check if eligible for a specific age range
    method is_age_eligible ($min_age, $max_age, $as_of_date = time()) {
        my $current_age = $self->age($as_of_date);
        return 0 unless defined $current_age;
        
        return 0 if defined $min_age && $current_age < $min_age;
        return 0 if defined $max_age && $current_age > $max_age;
        return 1;
    }
    
    # Check if eligible for a specific grade
    method is_grade_eligible ($required_grades) {
        return 1 unless $required_grades && @$required_grades;
        return 0 unless $grade;
        
        return grep { $_ eq $grade } @$required_grades;
    }
    
    # Get the parent/family user
    method family ($db) {
        require Registry::DAO;
        Registry::DAO::User->find($db, { id => $family_id });
    }
    
    # Get enrollments for this child
    method enrollments ($db) {
        Registry::DAO::Enrollment->find($db, { family_member_id => $id });
    }
    
    # Get waitlist entries for this child
    method waitlist_entries ($db) {
        require Registry::DAO::Waitlist;
        Registry::DAO::Waitlist->find($db, { family_member_id => $id });
    }
}