use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::MultiChildSessionSelection :isa(Registry::DAO::WorkflowStep) {
    use Carp qw( croak );
    
    method process ($db, $form_data, $run = undef) {
        $run //= do { my $w = $self->workflow($db); $w->latest_run($db) };
        
        # Get selected children from run data
        my $selected_child_ids = $run->data->{selected_child_ids} || [];
        unless (@$selected_child_ids) {
            return {
                stay => 1,
                errors => ['No children selected. Please go back to child selection.']
            };
        }
        
        # Get location and program info from run data
        my $location_id = $run->data->{location_id};
        my $program_id = $run->data->{program_id};
        
        # Load children and check program type rules
        require Registry::DAO::Family;
        require Registry::DAO::ProgramType;
        require Registry::DAO::Session;
        
        # Scoped to the run's own family. An id that resolves is not thereby
        # ours: FamilyMember->find carries no family_id predicate and
        # SelectChildren harvests child_<id>=1 without an ownership check, so
        # an unscoped lookup admits any row in the tenant. That is not merely a
        # stranger's enrollment -- the snapshot below carries child_name,
        # birth_date and grade into the run, the payment metadata and the
        # confirmation email, and the live row it creates makes the victim
        # family's own paid cart read 'foreign', so their settlement refunds
        # their share and never seats them. family_members.family_id is the
        # run's user_id (Family::add_child sets it), so this is exact.
        my $family_id = $run->data->{user_id};
        # Never let structure become an operator. The controller strips
        # bracketed server-owned keys now, so this is belt to that brace --
        # and undef fails closed, because family_id is NOT NULL.
        $family_id = undef if ref $family_id;
        my @children;
        for my $child_id (@$selected_child_ids) {
            my $child = Registry::DAO::FamilyMember->find(
                $db, { id => $child_id, family_id => $family_id } );
            push @children, $child if $child;
        }
        
        # Get program type to check rules
        my $program;
        my $program_type;
        if ($program_id) {
            $program = Registry::DAO::Project->find($db, { id => $program_id });
            if ($program && $program->program_type_slug) {
                $program_type = Registry::DAO::ProgramType->find_by_slug(
                    $db, 
                    $program->program_type_slug
                );
            }
        }
        
        my $action = $form_data->{action} || '';
        
        if ($action eq 'select_sessions') {
            # Process session selections
            my %selections;  # child_id => session_id
            my @errors;

            # Collect selections from form; template emits session_for_<child_id>.
            # The capacity and age checks below iterate the selected children, so
            # a selection for anyone else would be enrolled unchecked -- and
            # unpriced, since Payment totals the children snapshot. Selections
            # must be a subset of the children this run actually chose.
            #
            # Keyed on @children -- the ids that RESOLVED to a row -- not on
            # $selected_child_ids, which is client data: SelectChildren harvests
            # child_<id>=1 checkboxes without checking they name anything. Keying
            # on the raw list validates the input against itself, and an
            # unresolvable id then rides into the cart priced by nothing, because
            # calculate_enrollment_total also iterates the resolved children. The
            # charge looks normal and settlement dies on
            # enrollments_family_member_id_fkey, inside the transaction, after
            # capture -- rolling back the paying child's enrollment and the
            # webhook dedup claim with it, so every redelivery reproduces it.
            my %is_selected = map { $_->id => 1 } @children;
            for my $key (keys %$form_data) {
                if ($key =~ /^session_for_(.+)$/) {
                    my $child_id = $1;
                    my $session_id = $form_data->{$key};

                    if ($session_id && $session_id ne 'none') {
                        unless ($is_selected{$child_id}) {
                            push @errors, "Session selected for a child that is not part of this registration";
                            next;
                        }
                        $selections{$child_id} = $session_id;
                    }
                }
            }
            
            # Validate selections
            for my $child (@children) {
                unless ($selections{$child->id}) {
                    push @errors, "Please select a session for " . $child->child_name;
                }
            }
            
            # Check program type rules
            if ($program_type && $program_type->same_session_for_siblings && @children > 1) {
                # All children must be in the same session
                my @unique_sessions = keys %{{ map { $_ => 1 } values %selections }};
                if (@unique_sessions > 1) {
                    push @errors, "All siblings must be enrolled in the same session for " .
                                  $program_type->name . " programs";
                }
            }

            # Validate capacity and age eligibility for each selection
            require Registry::DAO::Enrollment;
            for my $child (@children) {
                my $session_id = $selections{$child->id} or next;
                my $sess = Registry::DAO::Session->find($db, { id => $session_id });
                next unless $sess;

                # Check capacity using existing DAO method
                if ($sess->capacity) {
                    my $enrolled = Registry::DAO::Enrollment->count_for_session(
                        $db, $session_id, ['active', 'pending']
                    );
                    if ($enrolled >= $sess->capacity) {
                        push @errors, $sess->name . " is full. Please select a different session for " . $child->child_name;
                    }
                }

                # Check age eligibility using existing FamilyMember method
                if ($program && $program->metadata) {
                    my $meta = ref $program->metadata eq 'HASH' ? $program->metadata : {};
                    my $age_range = $meta->{age_range};
                    if ($age_range) {
                        unless ($child->is_age_eligible($age_range->{min}, $age_range->{max})) {
                            my $child_age = $child->age // 'unknown';
                            push @errors, $child->child_name . " (age $child_age) is not eligible for this program (ages $age_range->{min}-$age_range->{max})";
                        }
                    }
                }
            }

            if (@errors) {
                return {
                    stay => 1,
                    errors => \@errors,
                };
            }
            
            # Store selections in run data. Also snapshot the children array
            # so calculate_enrollment_total (called from the Payment step) can
            # iterate children and look up pricing without re-querying the family.
            my @enrollment_items;
            # Sorted. finalize_enrollment awards the last seats of a full
            # session in list order, so an unsorted hash walk lets Perl's
            # per-process key randomization decide which sibling loses a seat --
            # and with siblings at different prices, how much is refunded. Two
            # identical registrations would refund different amounts.
            for my $child_id (sort keys %selections) {
                push @enrollment_items, {
                    child_id   => $child_id,
                    session_id => $selections{$child_id},
                };
            }

            my @children_data = map {
                {
                    id         => $_->id,
                    first_name => $_->child_name,
                    last_name  => '',
                    birth_date => $_->birth_date,
                    grade      => $_->grade,
                }
            } @children;

            $run->update_data($db, {
                enrollment_items   => \@enrollment_items,
                session_selections => \%selections,
                children           => \@children_data,
            });
            
            # Move to payment step
            return { next_step => 'payment' };
        }
        else {
            # First visit - display available sessions
            return { stay => 1 };
        }
    }
    
    method prepare_template_data ($db, $run, $params = {}) {
        require Registry::DAO::Family;
        require Registry::DAO::Session;

        my $selected_child_ids = $run->data->{selected_child_ids} || [];
        my $location_id = $run->data->{location_id};
        my $program_id  = $run->data->{program_id};

        # Expand child IDs into the flat-hash format the template expects.
        # Scoped to the run's family for the same reason process is: rendering
        # a child we would refuse to process discloses their name and age, and
        # hands the client a session_for_<id> control aimed at them.
        my $family_id = $run->data->{user_id};
        # Never let structure become an operator. The controller strips
        # bracketed server-owned keys now, so this is belt to that brace --
        # and undef fails closed, because family_id is NOT NULL.
        $family_id = undef if ref $family_id;
        my @children;
        for my $child_id (@$selected_child_ids) {
            my $child = Registry::DAO::FamilyMember->find(
                $db, { id => $child_id, family_id => $family_id } );
            next unless $child;
            # Compute age as integer years from birth_date (ISO string).
            my $age = $child->age // 0;
            push @children, {
                id         => $child->id,
                first_name => $child->child_name,
                last_name  => '',
                age        => $age,
            };
        }

        # Query published sessions that belong to this program+location.
        my @available_sessions;
        if ($program_id && $location_id) {
            my $sql = q{
                SELECT DISTINCT s.*
                FROM sessions s
                JOIN session_events se ON se.session_id = s.id
                JOIN events e ON e.id = se.event_id
                WHERE e.location_id = ?
                  AND e.project_id  = ?
                  AND s.status      = 'published'
                  AND s.end_date    >= CURRENT_DATE
                ORDER BY s.start_date
            };
            my $rows = $db->query($sql, $location_id, $program_id)->hashes;
            for my $row (@$rows) {
                my $sess = Registry::DAO::Session->new(%$row);
                my $enrolled = $db->query(
                    q{SELECT COUNT(*) FROM enrollments
                      WHERE session_id = ? AND status IN ('active','pending')},
                    $sess->id
                )->array->[0] || 0;
                push @available_sessions, $sess
                    unless ($sess->capacity && $enrolled >= $sess->capacity);
            }
        } elsif ($program_id) {
            # No location filter — find any published session for this program.
            my $sql = q{
                SELECT DISTINCT s.*
                FROM sessions s
                JOIN session_events se ON se.session_id = s.id
                JOIN events e ON e.id = se.event_id
                WHERE e.project_id = ?
                  AND s.status     = 'published'
                  AND s.end_date   >= CURRENT_DATE
                ORDER BY s.start_date
            };
            my $rows = $db->query($sql, $program_id)->hashes;
            for my $row (@$rows) {
                my $sess = Registry::DAO::Session->new(%$row);
                my $enrolled = $db->query(
                    q{SELECT COUNT(*) FROM enrollments
                      WHERE session_id = ? AND status IN ('active','pending')},
                    $sess->id
                )->array->[0] || 0;
                push @available_sessions, $sess
                    unless ($sess->capacity && $enrolled >= $sess->capacity);
            }
        }

        return {
            children           => \@children,
            available_sessions => \@available_sessions,
        };
    }

    method validate ($db, $form_data) {
        my $action = $form_data->{action} || '';
        
        if ($action eq 'select_sessions') {
            my @errors;
            my $has_selection = 0;
            
            for my $key (keys %$form_data) {
                if ($key =~ /^session_for_.+$/ &&
                    $form_data->{$key} &&
                    $form_data->{$key} ne 'none') {
                    $has_selection = 1;
                    last;
                }
            }
            
            push @errors, 'Please select at least one session' unless $has_selection;
            
            return @errors ? \@errors : undef;
        }
        
        return;
    }
    
    method get_available_sessions ($db, $location_id, $program_id, $child) {
        # Get sessions that:
        # 1. Are at the specified location
        # 2. Match the program
        # 3. Are age-appropriate for the child
        # 4. Have available capacity
        
        my $sql = q{
            SELECT DISTINCT s.*
            FROM sessions s
            JOIN session_events se ON se.session_id = s.id
            JOIN events e ON e.id = se.event_id
            WHERE e.location_id = ?
            AND e.project_id = ?
            AND s.status = 'published'
            AND (e.min_age IS NULL OR e.min_age <= ?)
            AND (e.max_age IS NULL OR e.max_age >= ?)
            AND s.end_date >= CURRENT_DATE
            -- s.id breaks ties: sessions sharing a start_date (a morning and
            -- an afternoon of the same week) would otherwise come back in
            -- whatever order Postgres chose, reshuffling the list between
            -- page loads.
            ORDER BY s.start_date, s.id
        };
        
        my $child_age = $child->age();
        my $results = $db->query($sql, $location_id, $program_id, $child_age, $child_age)->hashes;
        
        my @available_sessions;
        for my $row (@$results) {
            my $session = Registry::DAO::Session->new(%$row);
            
            # Check capacity
            my $capacity = $session->capacity || 0;
            my $enrolled = $db->select('enrollments', 'COUNT(*)', {
                session_id => $session->id,
                status => ['active', 'pending']
            })->array->[0];
            
            if (!$capacity || $enrolled < $capacity) {
                push @available_sessions, {
                    session => $session,
                    available_spots => $capacity ? $capacity - $enrolled : undef,
                    is_full => 0,
                };
            }
        }
        
        return \@available_sessions;
    }
}