use v5.34.0;
use utf8;
use experimental qw(try);
use Object::Pad;

class Registry::DAO::FamilyMember :isa(Registry::DAO::Object) {
    use Carp qw( croak );
    use Mojo::JSON qw( decode_json encode_json );
    
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
    
    use constant table => 'family_members';
    
    BUILD {
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
        Registry::DAO::Enrollment->find_all($db, { family_member_id => $id });
    }
    
    # Get waitlist entries for this child
    method waitlist_entries ($db) {
        require Registry::DAO::Waitlist;
        Registry::DAO::Waitlist->find_all($db, { family_member_id => $id });
    }
}

class Registry::DAO::Family {
    use Carp qw( croak );
    
    # Add a child to a family
    sub add_child ($class, $db, $family_id, $child_data) {
        $child_data->{family_id} = $family_id;
        Registry::DAO::FamilyMember->create($db, $child_data);
    }
    
    # Update a child's information
    sub update_child ($class, $db, $child_id, $child_data) {
        my $child = Registry::DAO::FamilyMember->find($db, { id => $child_id });
        croak "Child not found" unless $child;
        
        $child->update($db, $child_data);
    }
    
    # List all children in a family
    sub list_children ($class, $db, $family_id) {
        my $results = $db->select(
            'family_members',
            undef,
            { family_id => $family_id },
            { -asc => 'birth_date' }
        )->hashes;
        
        return [ map { Registry::DAO::FamilyMember->new(%$_) } @$results ];
    }
    
    # Find eligible children for a session/event
    sub find_eligible_children ($class, $db, $family_id, $requirements = {}) {
        my $children = $class->list_children($db, $family_id);
        my @eligible;
        
        for my $child (@$children) {
            # Check age eligibility
            if (defined $requirements->{min_age} || defined $requirements->{max_age}) {
                next unless $child->is_age_eligible(
                    $requirements->{min_age},
                    $requirements->{max_age},
                    $requirements->{as_of_date}
                );
            }
            
            # Check grade eligibility
            if ($requirements->{grades}) {
                next unless $child->is_grade_eligible($requirements->{grades});
            }
            
            push @eligible, $child;
        }
        
        return \@eligible;
    }
    
    # Check if family has multiple children
    sub has_multiple_children ($class, $db, $family_id) {
        my $count = $db->select('family_members', 'COUNT(*)', { family_id => $family_id })->array->[0];
        return $count > 1;
    }
    
    # Get sibling discount eligibility
    sub sibling_discount_eligible ($class, $db, $family_id, $session_id) {
        # Count active enrollments for this family in the session
        my $sql = q{
            SELECT COUNT(DISTINCT fm.id) 
            FROM family_members fm
            JOIN enrollments e ON e.family_member_id = fm.id
            WHERE fm.family_id = ?
            AND e.session_id = ?
            AND e.status IN ('active', 'pending')
        };
        
        my $enrolled_count = $db->query($sql, $family_id, $session_id)->array->[0];
        return $enrolled_count >= 2;
    }
}