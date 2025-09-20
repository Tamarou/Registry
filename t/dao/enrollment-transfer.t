use 5.40.2;
use lib          qw(lib t/lib);
use experimental qw(defer builtin);

use Test::More import => [qw( done_testing is ok fail subtest diag like )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;

my $test_db = Test::Registry::DB->new();
my $dao = $test_db->db;

# Import the workflows that TransferRequest DAO depends on
use Mojo::File qw(path);
my @workflow_files = path('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;
$dao->import_workflows(\@workflow_files); # Uses the new DAO helper method

# Set up test data
my $parent_user = $dao->create(User => {
    username => 'test_parent_enroll_transfer',
    user_type => 'parent',
    email => 'parent@enroll.transfer.test',
    name => 'Enroll Transfer Parent'
});

my $admin_user = $dao->create(User => {
    username => 'test_admin_enroll_transfer',
    user_type => 'admin',
    email => 'admin@enroll.transfer.test',
    name => 'Enroll Transfer Admin'
});

my $family_member = $dao->create(FamilyMember => {
    family_id => $parent_user->id,
    child_name => 'Enroll Transfer Child',
    birth_date => '2010-01-01',
    grade => '8th'
});

my $source_session = $dao->create(Session => {
    name => 'Source Enrollment Session',
    start_date => '2024-01-01',
    end_date => '2024-01-15',
    capacity => 10
});

my $target_session = $dao->create(Session => {
    name => 'Target Enrollment Session',
    start_date => '2024-02-01',
    end_date => '2024-02-15',
    capacity => 5
});

my $full_session = $dao->create(Session => {
    name => 'Full Session',
    start_date => '2024-03-01',
    end_date => '2024-03-15',
    capacity => 1
});

my $enrollment = $dao->create(Enrollment => {
    session_id => $source_session->id,
    student_id => $family_member->id,
    family_member_id => $family_member->id,
    parent_id => $parent_user->id,
    status => 'active'
});

# Create enrollment for admin transfer test (used in multiple subtests)
my $admin_test_family_member = $dao->create(FamilyMember => {
    family_id => $parent_user->id,
    child_name => 'Admin Test Child',
    birth_date => '2010-01-01',
    grade => '8th'
});

my $admin_test_enrollment = $dao->create(Enrollment => {
    session_id => $source_session->id,
    student_id => $admin_test_family_member->id,
    family_member_id => $admin_test_family_member->id,
    parent_id => $parent_user->id,
    status => 'active'
});

subtest 'Can transfer enrollment permissions' => sub {
    # Admin can always transfer
    ok $enrollment->can_transfer($dao->db, $admin_user), 'Admin can transfer enrollments';

    # Parent can request transfers (requires admin approval)
    ok $enrollment->can_transfer($dao->db, $parent_user), 'Parent can request transfers';
};

subtest 'Transfer request creation with validation' => sub {
    # Valid transfer request
    my $result = $enrollment->request_transfer($dao->db, $parent_user, $target_session->id, 'Schedule conflict');

    ok $result->{success}, 'Transfer request created successfully';
    ok $result->{transfer_request}, 'Transfer request object returned';
    is $result->{transfer_request}->status, 'pending', 'Transfer request has pending status';
    is $result->{transfer_request}->reason, 'Schedule conflict', 'Reason stored correctly';
    is $result->{transfer_request}->target_session_id, $target_session->id, 'Target session ID correct';
    is $result->{transfer_request}->enrollment_id, $enrollment->id, 'Enrollment ID correct';
    is $result->{transfer_request}->requested_by, $parent_user->id, 'Requested by parent ID correct';
};

subtest 'Transfer request validation - nonexistent target session' => sub {
    # Create a separate enrollment for this test to avoid state pollution
    my $nonexistent_test_family_member = $dao->create(FamilyMember => {
        family_id => $parent_user->id,
        child_name => 'Nonexistent Test Child',
        birth_date => '2010-01-01',
        grade => '8th'
    });

    my $nonexistent_test_enrollment = $dao->create(Enrollment => {
        session_id => $source_session->id,
        student_id => $nonexistent_test_family_member->id,
        family_member_id => $nonexistent_test_family_member->id,
        parent_id => $parent_user->id,
        status => 'active'
    });

    my $nonexistent_session_id = '00000000-0000-0000-0000-000000000000';
    my $result = $nonexistent_test_enrollment->request_transfer($dao->db, $parent_user, $nonexistent_session_id, 'Test reason');

    ok $result->{error}, 'Error returned for nonexistent session';
    like $result->{error}, qr/Target session not found/, 'Appropriate error message for nonexistent session';
};

subtest 'Transfer request validation - full target session' => sub {
    # Create a separate enrollment for this test to avoid state pollution
    my $full_test_family_member = $dao->create(FamilyMember => {
        family_id => $parent_user->id,
        child_name => 'Full Session Test Child',
        birth_date => '2010-01-01',
        grade => '8th'
    });

    my $full_test_enrollment = $dao->create(Enrollment => {
        session_id => $source_session->id,
        student_id => $full_test_family_member->id,
        family_member_id => $full_test_family_member->id,
        parent_id => $parent_user->id,
        status => 'active'
    });

    # Create additional family members to fill up the session
    my @test_family_members;
    for my $i (1..$full_session->capacity) {
        my $test_family_member = $dao->create(FamilyMember => {
            family_id => $parent_user->id,
            child_name => "Test Child $i",
            birth_date => '2010-01-01',
            grade => '8th'
        });
        push @test_family_members, $test_family_member;

        my $fill_enrollment = $dao->create(Enrollment => {
            session_id => $full_session->id,
            student_id => $test_family_member->id,
            family_member_id => $test_family_member->id,
            parent_id => $parent_user->id,
            status => 'active'
        });
    }

    my $result = $full_test_enrollment->request_transfer($dao->db, $parent_user, $full_session->id, 'Test reason');

    ok $result->{error}, 'Error returned for full session';
    like $result->{error}, qr/Target session is full/, 'Appropriate error message for full session';
};

subtest 'Complete transfer process by admin' => sub {
    # Create a transfer request first
    my $result = $admin_test_enrollment->request_transfer($dao->db, $parent_user, $target_session->id, 'Admin transfer test');
    my $transfer_request = $result->{transfer_request};

    # Approve the transfer
    $transfer_request->approve($dao->db, $admin_user, 'Approved for testing');

    # Verify enrollment was transferred
    my $updated_enrollment = Registry::DAO::Enrollment->find($dao->db, { id => $admin_test_enrollment->id });
    is $updated_enrollment->session_id, $target_session->id, 'Enrollment session updated to target';
    is $updated_enrollment->transfer_to_session_id, $target_session->id, 'Transfer to session ID recorded';
    is $updated_enrollment->transfer_status, 'completed', 'Transfer status marked as completed';

    # Verify transfer request status
    my $updated_request = Registry::DAO::TransferRequest->find($dao->db, { id => $transfer_request->id });
    is $updated_request->status, 'approved', 'Transfer request marked as approved';
    ok defined $updated_request->processed_at, 'Transfer request processing timestamp recorded';
    is $updated_request->processed_by, $admin_user->id, 'Transfer request processed by admin';
};

subtest 'Transfer status helper methods' => sub {
    # Create a separate family member for this test to avoid duplicate key constraint
    my $test_family_member = $dao->create(FamilyMember => {
        family_id => $parent_user->id,
        child_name => 'Transfer Status Test Child',
        birth_date => '2010-01-01',
        grade => '8th'
    });

    # Test with enrollment that has no transfer
    my $no_transfer_enrollment = $dao->create(Enrollment => {
        session_id => $source_session->id,
        student_id => $test_family_member->id,
        family_member_id => $test_family_member->id,
        parent_id => $parent_user->id,
        status => 'active'
    });

    ok !$no_transfer_enrollment->is_transfer_pending, 'No transfer shows not pending';
    ok !$no_transfer_enrollment->is_transfer_completed, 'No transfer shows not completed';
    ok !$no_transfer_enrollment->has_transfer_request, 'No transfer shows no request';

    # Test with completed transfer (from previous subtest)
    my $transferred_enrollment = Registry::DAO::Enrollment->find($dao->db, { id => $admin_test_enrollment->id });
    ok !$transferred_enrollment->is_transfer_pending, 'Completed transfer shows not pending';
    ok $transferred_enrollment->is_transfer_completed, 'Completed transfer shows completed';
    ok $transferred_enrollment->has_transfer_request, 'Completed transfer shows has request';

    # Test with pending transfer - create another unique family member
    my $pending_test_family_member = $dao->create(FamilyMember => {
        family_id => $parent_user->id,
        child_name => 'Pending Transfer Test Child',
        birth_date => '2010-01-01',
        grade => '8th'
    });

    my $pending_enrollment = $dao->create(Enrollment => {
        session_id => $source_session->id,
        student_id => $pending_test_family_member->id,
        family_member_id => $pending_test_family_member->id,
        parent_id => $parent_user->id,
        status => 'active'
    });

    # Update to have pending transfer status
    $pending_enrollment->update($dao->db, { transfer_status => 'requested' });
    $pending_enrollment = Registry::DAO::Enrollment->find($dao->db, { id => $pending_enrollment->id });

    ok $pending_enrollment->is_transfer_pending, 'Pending transfer shows pending';
    ok !$pending_enrollment->is_transfer_completed, 'Pending transfer shows not completed';
    ok $pending_enrollment->has_transfer_request, 'Pending transfer shows has request';
};