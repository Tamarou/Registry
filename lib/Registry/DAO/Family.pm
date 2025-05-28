use 5.40.2;
use Object::Pad;

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