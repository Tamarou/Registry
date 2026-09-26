#!/usr/bin/env perl
# ABOUTME: Tests for MultiChildSessionSelection workflow step using real production interfaces
# ABOUTME: Validates session selection for multiple children with age and capacity constraints
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::User;
use Registry::DAO::Family;
use Registry::DAO::Session;
use Registry::DAO::Project;
use Registry::DAO::Event;
use Registry::DAO::Location;
use Registry::DAO::ProgramType;
use Registry::DAO::WorkflowSteps::MultiChildSessionSelection;
use Mojo::JSON qw(encode_json);

# This suite asserts eligibility, which is a function of age and of a
# session still being in the future -- both measured against the day the
# test runs. Hardcoded dates silently expire, so derive them.

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

# Create test tenant and set up schema
my $tenant = Test::Registry::Fixtures::create_tenant($dao->db, {
    name => 'Test MultiChild Session Tenant',
    slug => 'test_multi_session',
});

# Switch to tenant schema
$dao = Registry::DAO->new(url => $test_db->uri, schema => 'test_multi_session');
my $db = $dao->db;

# Create test data
my $location = Registry::DAO::Location->create($db, {
    name => 'Test Location',
    address_info => {
        street_address => '123 Main St',
        city => 'Test City',
        state => 'TS',
        postal_code => '12345'
    },
    metadata => {}
});

# Create teacher and project
my $teacher = Registry::DAO::User->create($db, {
    name => 'Test Teacher',
    username => 'testteacher',
    email => 'teacher@test.com',
    user_type => 'staff'
});

my $project = Registry::DAO::Project->create($db, {
    name => 'Test Project',
    metadata => {}
});

# The events belong to the sessions created below, so they sit in the same
# week rather than at a fixed date of their own. Events are unique per
# project, location and time, so they fall on consecutive days.
my $first_event_day  = days_from_now(30);
my $second_event_day = days_from_now(31);

# Create events with different age ranges
my $event1 = Registry::DAO::Event->create($db, {
    time => "$first_event_day 10:00:00",
    duration => 120,
    location_id => $location->id,
    project_id => $project->id,
    teacher_id => $teacher->id,
    metadata => {},
    capacity => 10,
    min_age => 6,
    max_age => 10
});

my $event2 = Registry::DAO::Event->create($db, {
    time => "$second_event_day 10:00:00",
    duration => 120,
    location_id => $location->id,
    project_id => $project->id,
    teacher_id => $teacher->id,
    metadata => {},
    capacity => 5,
    min_age => 8,
    max_age => 12
});

# Create sessions with future dates and capacity limits
# Both sessions run the same week -- get_available_sessions filters on
# end_date >= CURRENT_DATE, so the window has to stay ahead of today.
my $session1 = Registry::DAO::Session->create($db, {
    name => 'Morning Session',
    start_date => days_from_now(30),
    end_date => days_from_now(37),
    status => 'published',
    capacity => 10,
    metadata => {}
});

my $session2 = Registry::DAO::Session->create($db, {
    name => 'Afternoon Session',
    start_date => days_from_now(30),
    end_date => days_from_now(37),
    status => 'published',
    capacity => 5,
    metadata => {}
});

# Link events to sessions
$session1->add_events($db, $event1->id);
$session2->add_events($db, $event2->id);

# Create program type with sibling rules
my $program_type = Registry::DAO::ProgramType->create($db, {
    name => 'Family Program',
    slug => 'family-program',
    config => {
        enrollment_rules => {
            same_session_for_siblings => 1
        }
    }
});

# Update project to use program type
$project->update($db, { program_type_slug => $program_type->slug });

# Create workflow
my $workflow = Registry::DAO::Workflow->create($db, {
    name => 'Test Multi-Child Session Workflow',
    slug => 'test-multi-child-session-workflow',
    description => 'Test workflow for multi-child session selection'
});

# Add session selection workflow step
my $session_step_data = Registry::DAO::WorkflowStep->create($db, {
    workflow_id => $workflow->id,
    slug => 'session-selection',
    class => 'Registry::DAO::WorkflowSteps::MultiChildSessionSelection',
    description => 'Session selection step'
});

# Update workflow to set first step
$workflow->update($db, { first_step => 'session-selection' }, { id => $workflow->id });

# Create test parent user
my $parent = Registry::DAO::User->create($db, {
    email    => 'parent@example.com',
    username => 'testparent',
    password => 'password123',
    name => 'Test Parent',
    user_type => 'parent'
});

# Add children to family - one eligible for both sessions, one only for session2
my $child1 = Registry::DAO::Family->add_child($db, $parent->id, {
    child_name => 'Alice Smith',
    birth_date => birth_date_for_age(8),  # eligible for both sessions
    grade => '3',
    medical_info => {},
    emergency_contact => {
        name => 'Emergency Contact',
        phone => '555-0123',
        relationship => 'grandparent'
    }
});

my $child2 = Registry::DAO::Family->add_child($db, $parent->id, {
    child_name => 'Bob Smith',
    birth_date => birth_date_for_age(6),  # under event2's min_age, so session1 only
    grade => '1',
    medical_info => {},
    emergency_contact => {
        name => 'Emergency Contact',
        phone => '555-0123',
        relationship => 'aunt'
    }
});

subtest 'Initial page load without selected children' => sub {
    my $run = $workflow->new_run($db);

    # Get the actual step from database
    my $step = $workflow->get_step($db, { slug => 'session-selection' });

    # Process step without selected_child_ids in run data
    my $result = $step->process($db, {});

    ok $result->{stay}, 'Stays on step';
    ok $result->{errors}, 'Returns errors';
    like $result->{errors}->[0], qr/No children selected/, 'Correct error message';
};

subtest 'Initial page load with selected children' => sub {
    my $run = $workflow->new_run($db);

    # Set up run data as if coming from select-children step
    $run->update_data($db, {
        user_id => $parent->id,
        selected_child_ids => [$child1->id, $child2->id],
        location_id => $location->id,
        program_id => $project->id,
    });

    # Get the actual step from database
    my $step = $workflow->get_step($db, { slug => 'session-selection' });

    # Process step without action (first visit)
    my $result = $step->process($db, {});

    ok $result->{stay}, 'Stays on step for initial load';
    ok !$result->{errors}, 'No errors on initial load';
};

subtest 'Submit without session selections' => sub {
    my $run = $workflow->new_run($db);
    $run->update_data($db, {
        user_id => $parent->id,
        selected_child_ids => [$child1->id, $child2->id],
        location_id => $location->id,
        program_id => $project->id,
    });

    my $step = $workflow->get_step($db, { slug => 'session-selection' });

    my $result = $step->process($db, {
        action => 'select_sessions',
        # No session selections provided
    });

    ok $result->{stay}, 'Stays on step';
    ok $result->{errors}, 'Returns validation errors';
    is scalar(@{$result->{errors}}), 2, 'Two validation errors (one per child)';
    like $result->{errors}->[0], qr/Please select a session for/, 'Child selection error';
};

subtest 'Submit with valid session selections' => sub {
    my $run = $workflow->new_run($db);
    $run->update_data($db, {
        user_id => $parent->id,
        selected_child_ids => [$child1->id, $child2->id],
        location_id => $location->id,
        program_id => $project->id,
    });

    my $step = $workflow->get_step($db, { slug => 'session-selection' });

    my $result = $step->process($db, {
        action => 'select_sessions',
        "session_for_" . $child1->id => $session1->id,
        "session_for_" . $child2->id => $session1->id,
    });

    ok !$result->{stay}, 'Moves to next step';
    ok !$result->{errors}, 'No errors';
    is $result->{next_step}, 'payment', 'Moves to payment step';

    # Check run data was updated
    my $updated_run = $workflow->latest_run($db);
    my $data = $updated_run->data;

    ok $data->{enrollment_items}, 'Enrollment items stored';
    is scalar(@{$data->{enrollment_items}}), 2, 'Two enrollment items';
    ok $data->{session_selections}, 'Session selections stored';

    # Deterministic order. finalize_enrollment awards the last seats of a full
    # session in list order, so an unsorted hash walk lets Perl's per-process
    # key randomization decide which sibling loses a seat -- and with siblings
    # at different prices, how much is refunded. Two identical registrations
    # would refund different amounts.
    #
    # Detection here is probabilistic, not strong: with two children an
    # unsorted hash walk produces the sorted order half the time, so this
    # catches a regression on roughly every other run. It never false-fails --
    # sorted code always passes -- but the durable guard is the `sort` in
    # MultiChildSessionSelection and the comment beside it, not this assertion.
    is_deeply [ map { $_->{child_id} } @{ $data->{enrollment_items} } ],
        [ sort ( $child1->id, $child2->id ) ],
        'Enrollment items are in a deterministic order, not hash order';

    # Check session selections
    is $data->{session_selections}->{$child1->id}, $session1->id, 'Child1 session stored';
    is $data->{session_selections}->{$child2->id}, $session1->id, 'Child2 session stored';

    # The children snapshot feeds Payment::calculate_enrollment_total; without
    # it the total degenerates to $0 and paid enrollment silently goes free,
    # bypassing the Connect readiness gate.
    ok $data->{children}, 'children snapshot stored in run data';
    is scalar(@{$data->{children}}), 2, 'both selected children snapshotted';
    my %child_ids = map { $_->{id} => 1 } @{$data->{children}};
    ok $child_ids{$child1->id} && $child_ids{$child2->id},
        'snapshot carries both child ids';
    ok defined $data->{children}[0]{first_name},
        'snapshot carries the first_name field the payment description uses';
    ok exists $data->{children}[0]{last_name},
        'snapshot carries a last_name key (empty string; family members have no surname)';
};

subtest 'Program type sibling rule validation' => sub {
    my $run = $workflow->new_run($db);
    $run->update_data($db, {
        user_id => $parent->id,
        selected_child_ids => [$child1->id, $child2->id],
        location_id => $location->id,
        program_id => $project->id,
    });

    my $step = $workflow->get_step($db, { slug => 'session-selection' });

    # Try to select different sessions for siblings with a program type that requires same session
    my $result = $step->process($db, {
        action => 'select_sessions',
        "session_for_" . $child1->id => $session1->id,
        "session_for_" . $child2->id => $session2->id,  # Different session
    });

    ok $result->{stay}, 'Stays on step';
    ok $result->{errors}, 'Returns validation errors';
    like $result->{errors}->[0], qr/All siblings must be enrolled in the same session/, 'Sibling rule error';
};

subtest 'get_available_sessions method' => sub {
    my $run = $workflow->new_run($db);
    $run->update_data($db, {
        user_id => $parent->id,
        selected_child_ids => [$child1->id, $child2->id],
        location_id => $location->id,
        program_id => $project->id,
    });

    my $step = $workflow->get_step($db, { slug => 'session-selection' });

    # Get available sessions for child1 (9 years old - eligible for both)
    my $available1 = $step->get_available_sessions($db, $location->id, $project->id, $child1);
    is scalar(@$available1), 2, 'Child1 has 2 available sessions';

    # Get available sessions for child2 (7 years old - only eligible for session1)
    my $available2 = $step->get_available_sessions($db, $location->id, $project->id, $child2);
    is scalar(@$available2), 1, 'Child2 has 1 available session';
    is $available2->[0]->{session}->id, $session1->id, 'Child2 eligible for session1';
};

subtest 'Validation method tests' => sub {
    my $run = $workflow->new_run($db);
    $run->update_data($db, { user_id => $parent->id });

    my $step = $workflow->get_step($db, { slug => 'session-selection' });

    # Test select_sessions validation without selections
    my $errors = $step->validate($db, {
        action => 'select_sessions',
        # No session selections
    });

    ok $errors, 'validate() method returns errors when no sessions selected';
    like $errors->[0], qr/Please select at least one session/, 'Correct validation error message';

    # Test with selections
    $errors = $step->validate($db, {
        action => 'select_sessions',
        "session_for_" . $child1->id => $session1->id,
    });

    ok !$errors, 'No validation errors with selections';

    # Test without action
    $errors = $step->validate($db, {});
    ok !$errors, 'No validation errors without action';
};

subtest 'Session capacity constraints' => sub {
    # Create test students and fill up session2 to test capacity constraints
    for my $i (1..5) {
        my $test_student = Registry::DAO::User->create($db, {
            email => "student$i\@test.com",
            username => "student$i",
            name => "Test Student $i",
            user_type => 'parent'
        });

        $db->insert('enrollments', {
            session_id => $session2->id,
            student_id => $test_student->id,
            status => 'active'
        });
    }

    my $run = $workflow->new_run($db);
    $run->update_data($db, {
        user_id => $parent->id,
        selected_child_ids => [$child1->id],
        location_id => $location->id,
        program_id => $project->id,
    });

    my $step = $workflow->get_step($db, { slug => 'session-selection' });

    # Get available sessions for child1 - session2 should be filtered out due to capacity
    my $available1 = $step->get_available_sessions($db, $location->id, $project->id, $child1);

    # A full session is still OFFERED, marked full, so the parent can choose to
    # wait for it. Hiding it was a dead end: the storefront invites them to
    # "Join Waitlist" and this screen then had nothing for them to pick.
    is scalar(@$available1), 2, 'both sessions are offered';

    my ($open) = grep { $_->{session}->id eq $session1->id } @$available1;
    my ($full) = grep { $_->{session}->id eq $session2->id } @$available1;

    ok $open, 'the session with room is offered';
    is $open->{is_full}, 0, 'and is not marked full';

    ok $full, 'the full session is offered too';
    is $full->{is_full}, 1, 'marked full, so the screen can say so';
    is $full->{available_spots}, 0, 'with no places left';
};

# session2 was filled to capacity by the subtest above, so this exercises the
# real thing: one child takes the session with room, the other chooses to wait
# for the full one. Which of those a parent prefers is theirs to decide -- the
# screen offers both and this records what they picked.
# session2 was filled to capacity by the subtest above, so this exercises the
# real thing: a parent chooses the session they wanted even though it is full,
# and waits for it. Whether to wait or take one with room is their decision --
# the screen offers both, and this records what they picked.
#
# One child, because this project sets same_session_for_siblings: a mixed
# cart across two sessions is refused by that rule before capacity is even
# looked at, which is a different question from this one.
subtest 'choosing a full session puts that child on the waitlist' => sub {
    my $run = $workflow->new_run($db);
    $run->update_data($db, {
        user_id            => $parent->id,
        selected_child_ids => [ $child1->id ],
        location_id        => $location->id,
        program_id         => $project->id,
    });

    my $step = $workflow->get_step($db, { slug => 'session-selection' });

    my $result = $step->process($db, {
        action => 'select_sessions',
        "session_for_" . $child1->id => $session2->id,   # full
    });

    ok !$result->{errors}, 'the full choice is not refused'
        or diag 'errors: ' . join( '; ', ( $result->{errors} // [] )->@* );

    my $data = $workflow->latest_run($db)->data;

    # Keeping a waiting child out of session_selections is what stops them
    # being charged for a seat that does not exist: calculate_enrollment_total
    # walks exactly that key.
    is_deeply [ keys %{ $data->{session_selections} // {} } ], [],
        'nobody is enrolling, so nothing reaches the paid side';
    is scalar @{ $data->{enrollment_items} // [] }, 0, 'and there are no enrollment items';

    is_deeply $data->{waitlist_items},
        [ { child_id => $child1->id, session_id => $session2->id,
            location_id => $location->id } ],
        'the waiting child is recorded against the session they chose';
};

# Morgan can turn a session's waitlist off -- a session that will not run
# again, or one where waiting would mislead rather than help. Then a full
# session is simply full: it is not offered, and choosing it is refused the
# way it always was.
subtest 'a full session with its waitlist off is not offered' => sub {
    $db->query( 'UPDATE sessions SET waitlist_enabled = FALSE WHERE id = ?', $session2->id );

    my $run = $workflow->new_run($db);
    $run->update_data($db, {
        user_id            => $parent->id,
        selected_child_ids => [ $child1->id ],
        location_id        => $location->id,
        program_id         => $project->id,
    });
    my $step = $workflow->get_step($db, { slug => 'session-selection' });

    # prepare_template_data, not get_available_sessions: the latter is called
    # by nothing outside this file, so asserting on it would grade a method
    # the screen never reaches.
    my $rendered = $step->prepare_template_data($db, $run, {});
    ok !( grep { $_->{session}->id eq $session2->id }
              @{ $rendered->{available_sessions} || [] } ),
        'the full session is gone from what the screen renders';

    # And posting its id anyway -- a stale page, or someone typing -- is
    # refused rather than quietly waitlisting a child against Morgan's wishes.
    my $result = $step->process($db, {
        action => 'select_sessions',
        "session_for_" . $child1->id => $session2->id,
    });
    ok $result->{errors}, 'choosing it is refused';

    my $data = $workflow->latest_run($db)->data;
    is_deeply $data->{waitlist_items} // [], [],
        'and nobody was put on a waitlist that is switched off';

    $db->query( 'UPDATE sessions SET waitlist_enabled = TRUE WHERE id = ?', $session2->id );
};

subtest 'session_for_<id> for a child that was never selected' => sub {
    my $run = $workflow->new_run($db);
    $run->update_data($db, {
        user_id => $parent->id,
        selected_child_ids => [$child1->id],   # only child1 was chosen
        location_id => $location->id,
        program_id => $project->id,
    });

    my $step = $workflow->get_step($db, { slug => 'session-selection' });

    # session2 is at capacity from the subtest above. Because child2 is absent
    # from selected_child_ids, neither the capacity nor the age loop -- both of
    # which iterate the selected children -- ever looks at him, and Payment
    # prices the children array rather than enrollment_items, so he would
    # enroll unchecked and unpriced.
    my $result = $step->process($db, {
        action => 'select_sessions',
        "session_for_" . $child1->id => $session1->id,
        "session_for_" . $child2->id => $session2->id,
    }, $run);

    ok $result->{errors}, 'submission with an unselected child is rejected';
    ok $result->{stay}, 'run stays on the session-selection step';
    ok !$run->data->{enrollment_items},
        'no enrollment items are stored';
    ok !$run->data->{session_selections},
        'no session selections are stored';
};

# A cart item for a child that does not exist must not reach the payment.
#
# selected_child_ids is CLIENT data -- SelectChildren harvests child_<id>=1
# checkboxes without checking the ids resolve -- so validating selections
# against it validates the input against itself. @children holds only the ids
# that actually resolved, which is the set this step's own comment means by
# "the children this run actually chose".
#
# An unresolvable id is priced by nothing (calculate_enrollment_total iterates
# the resolved children), so the cart total and the Stripe charge look normal.
# It detonates at settlement, on enrollments_family_member_id_fkey, inside the
# transaction after capture -- rolling back the paying child's enrollment and
# the webhook dedup claim with it, so every redelivery reproduces it. That is
# precisely the "money taken, no enrollment, forever" failure this milestone
# exists to remove, reached through the front door.
subtest 'a session selection for a child that does not exist is refused' => sub {
    my $run = $workflow->new_run($db);
    my $ghost = '00000000-0000-0000-0000-0000000000ff';
    $run->update_data($db, {
        user_id => $parent->id,
        # As a hostile client would leave it: one real child, one invented.
        selected_child_ids => [ $child1->id, $ghost ],
        location_id => $location->id,
        program_id => $project->id,
    });

    my $step = $workflow->get_step($db, { slug => 'session-selection' });
    my $result = $step->process($db, {
        action                    => 'select_sessions',
        "session_for_" . $child1->id => $session1->id,
        "session_for_$ghost"         => $session1->id,
    });

    ok $result->{errors}, 'the selection is rejected';
    like join( ' ', @{ $result->{errors} } ), qr/not part of this registration/,
        'and it says why';

    my $items = $run->data->{enrollment_items} // [];
    ok !( grep { ( $_->{child_id} // '' ) eq $ghost } @$items ),
        'no cart item names a child that does not exist';
};

# A cart item for another family's child must not reach the payment.
#
# Validating selections against @children only means "these ids resolved to a
# row", not "these ids are ours": FamilyMember->find carries no family_id
# predicate, and SelectChildren harvests child_<id>=1 without an ownership
# check either. So a parent could post another family's child id and have it
# admitted as legitimate by construction.
#
# The cost is not merely a stranger's enrollment. The snapshot this step
# writes carries child_name, birth_date and grade into the run, the payment
# metadata and the confirmation email, and the live row it creates makes the
# victim family's own paid cart read 'foreign' -- so their settlement refunds
# their share and never seats them. family_members.family_id is the run's
# user_id (Family::add_child sets it), so the scope is exact, not a heuristic.
# Nothing prevented paying for a seat the child already holds. The settlement
# handles it correctly -- the original seat stands, the new cart's share is
# refunded -- but the refund does not recover Stripe's processing fee on the
# charge, which the platform pays as merchant of record. Repeatable at will,
# and what an honest parent triggers by re-registering a child they forgot was
# already enrolled. Refusing before the charge is strictly better.
subtest 'a child who already holds a live seat cannot be paid for again' => sub {
    my $seated_child = Registry::DAO::FamilyMember->create($db, {
        family_id  => $parent->id,
        child_name => 'Already Seated',
        birth_date => birth_date_for_age(8),
        grade      => '3',
    });

    # A seat from somewhere else entirely: no payment_id, as a free enrolment
    # or an admin add leaves it.
    $db->insert('enrollments', {
        session_id   => $session1->id,
        student_id   => $seated_child->id,
        parent_id    => $parent->id,
        student_type => 'family_member',
        status       => 'active',
    });

    my $run = $workflow->new_run($db);
    $run->update_data($db, {
        user_id            => $parent->id,
        selected_child_ids => [ $seated_child->id ],
        location_id        => $location->id,
        program_id         => $project->id,
    });

    my $step   = $workflow->get_step($db, { slug => 'session-selection' });
    my $result = $step->process($db, {
        action                             => 'select_sessions',
        "session_for_" . $seated_child->id => $session1->id,
    });

    ok $result->{errors}, 'the selection is rejected';
    like join( ' ', @{ $result->{errors} // [] } ), qr/already enrolled/i,
        'and it says why';

    my $items = $run->data->{enrollment_items} // [];
    is scalar(@$items), 0, 'nothing reaches the cart';
};

# The other half of the rule: a cancelled seat is released, so re-registering
# after a drop has to keep working.
subtest 'a cancelled seat does not block registering again' => sub {
    my $returning = Registry::DAO::FamilyMember->create($db, {
        family_id  => $parent->id,
        child_name => 'Dropped And Back',
        birth_date => birth_date_for_age(8),
        grade      => '3',
    });

    $db->insert('enrollments', {
        session_id   => $session1->id,
        student_id   => $returning->id,
        parent_id    => $parent->id,
        student_type => 'family_member',
        status       => 'cancelled',
    });

    my $run = $workflow->new_run($db);
    $run->update_data($db, {
        user_id            => $parent->id,
        selected_child_ids => [ $returning->id ],
        location_id        => $location->id,
        program_id         => $project->id,
    });

    my $step   = $workflow->get_step($db, { slug => 'session-selection' });
    my $result = $step->process($db, {
        action                          => 'select_sessions',
        "session_for_" . $returning->id => $session1->id,
    });

    ok !$result->{errors}, 'the selection is accepted'
        or diag join ' ', @{ $result->{errors} // [] };
};

subtest "a session selection for another family's child is refused" => sub {
    my $other_parent = Registry::DAO::User->create($db, {
        email     => 'other-parent@example.com',
        username  => 'otherparent',
        password  => 'password123',
        name      => 'Other Parent',
        user_type => 'parent',
    });

    my $other_child = Registry::DAO::Family->add_child($db, $other_parent->id, {
        child_name        => 'Mallory Other',
        birth_date        => birth_date_for_age(8),
        grade             => '3',
        medical_info      => {},
        emergency_contact => {
            name => 'Emergency Contact', phone => '555-0199',
            relationship => 'grandparent',
        },
    });

    my $run = $workflow->new_run($db);
    $run->update_data($db, {
        user_id => $parent->id,
        # As a hostile client would leave it: one of ours, one of theirs.
        selected_child_ids => [ $child1->id, $other_child->id ],
        location_id => $location->id,
        program_id  => $project->id,
    });

    my $step = $workflow->get_step($db, { slug => 'session-selection' });

    my $rendered = $step->prepare_template_data($db, $run);
    ok !( grep { $_->{id} eq $other_child->id } @{ $rendered->{children} // [] } ),
        "the form does not render another family's child";
    unlike encode_json( $rendered->{children} // [] ), qr/Mallory Other/,
        "and does not disclose their name";

    my $result = $step->process($db, {
        action                          => 'select_sessions',
        "session_for_" . $child1->id     => $session1->id,
        "session_for_" . $other_child->id => $session1->id,
    }, $run);

    ok $result->{errors}, 'the selection is rejected';

    my $items = $run->data->{enrollment_items} // [];
    ok !( grep { ( $_->{child_id} // '' ) eq $other_child->id } @$items ),
        "no cart item names another family's child";

    my $children = $run->data->{children} // [];
    # first_name, not child_name: the snapshot renames the column, and
    # asserting on the wrong key passes whether or not the hole is open.
    ok !( grep { ( $_->{first_name} // '' ) eq 'Mallory Other' } @$children ),
        "and their name is not snapshotted into the run";
};

done_testing;
