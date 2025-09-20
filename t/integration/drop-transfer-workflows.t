#!/usr/bin/env perl

use 5.40.2;
use experimental qw(try defer);
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO;
use DateTime;

defer { done_testing };

my $test_db = Test::Registry::DB->new();
my $dao = $test_db->db;

# Import workflows and templates for testing
system('carton exec ./registry workflow import registry') == 0
    or die "Failed to import workflows for testing";
system('carton exec ./registry template import registry') == 0
    or die "Failed to import templates for testing";

# Note: This test now includes both DROP and TRANSFER workflows implemented as proper workflows.

# Test data setup
sub setup_test_data {
    my $test_suffix = shift || int(rand(10000));
    my $setup = {};

    # Create admin user
    $setup->{admin_user} = $dao->create(User => {
        username => "admin_user_$test_suffix",
        user_type => 'admin',
        email => "admin_$test_suffix\@test.com",
        name => 'Admin User'
    });

    # Create parent user
    $setup->{parent_user} = $dao->create(User => {
        username => "parent_user_$test_suffix",
        user_type => 'parent',
        email => "parent_$test_suffix\@test.com",
        name => 'Parent User'
    });

    # Create family member
    $setup->{family_member} = $dao->create(FamilyMember => {
        family_id => $setup->{parent_user}->id,
        child_name => 'Test Child',
        birth_date => '2010-01-01',
        grade => '8th'
    });

    # Create location
    $setup->{location} = $dao->create(Location => {
        name => "Test School $test_suffix",
        slug => "test-school-$test_suffix",
        address_info => { street => '123 Test St', city => 'Test City', state => 'TS', zip => '12345' }
    });

    # Create project
    $setup->{project} = $dao->create(Project => {
        name => "Test Program $test_suffix",
        program_type_slug => 'afterschool',
        metadata => { description => 'Test program', status => 'active' }
    });

    # Create sessions
    my $now = time();

    # Future session (hasn't started)
    $setup->{future_session} = $dao->create(Session => {
        name => "Future Session $test_suffix",
        project_id => $setup->{project}->id,
        location_id => $setup->{location}->id,
        start_date => DateTime->from_epoch(epoch => $now + 86400 * 7)->iso8601,  # Next week
        end_date => DateTime->from_epoch(epoch => $now + 86400 * 77)->iso8601,   # 11 weeks later
        capacity => 10
    });

    # Current session (has started)
    $setup->{current_session} = $dao->create(Session => {
        name => "Current Session $test_suffix",
        project_id => $setup->{project}->id,
        location_id => $setup->{location}->id,
        start_date => DateTime->from_epoch(epoch => $now - 86400)->iso8601,      # Yesterday
        end_date => DateTime->from_epoch(epoch => $now + 86400 * 70)->iso8601,   # 10 weeks from now
        capacity => 10
    });

    # Target session for transfers
    $setup->{target_session} = $dao->create(Session => {
        name => "Target Session $test_suffix",
        project_id => $setup->{project}->id,
        location_id => $setup->{location}->id,
        start_date => DateTime->from_epoch(epoch => $now + 86400 * 14)->iso8601, # 2 weeks from now
        end_date => DateTime->from_epoch(epoch => $now + 86400 * 84)->iso8601,   # 12 weeks from now
        capacity => 5
    });

    # Full session (capacity 1)
    $setup->{full_session} = $dao->create(Session => {
        name => "Full Session $test_suffix",
        project_id => $setup->{project}->id,
        location_id => $setup->{location}->id,
        start_date => DateTime->from_epoch(epoch => $now + 86400 * 21)->iso8601, # 3 weeks from now
        end_date => DateTime->from_epoch(epoch => $now + 86400 * 91)->iso8601,   # 13 weeks from now
        capacity => 1
    });

    return $setup;
}

# Drop workflows will be implemented in a future iteration

subtest 'Transfer Workflow - Valid Transfer' => sub {
    my $setup = setup_test_data('valid');

    # Create enrollment in source session
    my $enrollment = $dao->create(Enrollment => {
        session_id => $setup->{future_session}->id,
        student_id => $setup->{family_member}->id,
        family_member_id => $setup->{family_member}->id,
        parent_id => $setup->{parent_user}->id,
        status => 'active'
    });

    # Request transfer to target session
    my $result = $enrollment->request_transfer($dao->db, $setup->{parent_user}, $setup->{target_session}->id, 'Better schedule fit');

    # Should create transfer request requiring admin approval
    ok $result->{success}, 'Transfer request created successfully';
    ok $result->{transfer_request}, 'Transfer request object returned';
    is $result->{transfer_request}->status, 'pending', 'Transfer request has pending status';
    is $result->{transfer_request}->target_session_id, $setup->{target_session}->id, 'Target session ID correct';

    # Check enrollment transfer status
    my $updated_enrollment = Registry::DAO::Enrollment->find($dao->db, { id => $enrollment->id });
    is $updated_enrollment->transfer_status, 'requested', 'Enrollment transfer status set to requested';

    # Admin approves the transfer
    my $transfer_request = $result->{transfer_request};
    $transfer_request->approve($dao->db, $setup->{admin_user}, 'Approved for better schedule');

    # Check final status
    $updated_enrollment = Registry::DAO::Enrollment->find($dao->db, { id => $enrollment->id });
    is $updated_enrollment->session_id, $setup->{target_session}->id, 'Enrollment moved to target session';
    is $updated_enrollment->transfer_status, 'completed', 'Transfer status marked as completed';
    is $updated_enrollment->transfer_to_session_id, $setup->{target_session}->id, 'Transfer to session ID recorded';

    my $updated_request = Registry::DAO::TransferRequest->find($dao->db, { id => $transfer_request->id });
    is $updated_request->status, 'approved', 'Transfer request marked as approved';
};

subtest 'Transfer Workflow - Full Target Session' => sub {
    my $setup = setup_test_data('full');

    # Fill the full session to capacity
    my $fill_family_member = $dao->create(FamilyMember => {
        family_id => $setup->{parent_user}->id,
        child_name => 'Fill Child',
        birth_date => '2010-01-01',
        grade => '8th'
    });

    my $fill_enrollment = $dao->create(Enrollment => {
        session_id => $setup->{full_session}->id,
        student_id => $fill_family_member->id,
        family_member_id => $fill_family_member->id,
        parent_id => $setup->{parent_user}->id,
        status => 'active'
    });

    # Create enrollment to transfer
    my $enrollment = $dao->create(Enrollment => {
        session_id => $setup->{future_session}->id,
        student_id => $setup->{family_member}->id,
        family_member_id => $setup->{family_member}->id,
        parent_id => $setup->{parent_user}->id,
        status => 'active'
    });

    # Attempt transfer to full session
    my $result = $enrollment->request_transfer($dao->db, $setup->{parent_user}, $setup->{full_session}->id, 'Test reason');

    # Should fail with appropriate error
    ok $result->{error}, 'Transfer to full session rejected';
    like $result->{error}, qr/Target session is full/, 'Appropriate error message for full session';
};

subtest 'Transfer Workflow - Nonexistent Target Session' => sub {
    my $setup = setup_test_data('nonexistent');

    # Create enrollment
    my $enrollment = $dao->create(Enrollment => {
        session_id => $setup->{future_session}->id,
        student_id => $setup->{family_member}->id,
        family_member_id => $setup->{family_member}->id,
        parent_id => $setup->{parent_user}->id,
        status => 'active'
    });

    # Attempt transfer to nonexistent session
    my $nonexistent_session_id = '00000000-0000-0000-0000-000000000000';
    my $result = $enrollment->request_transfer($dao->db, $setup->{parent_user}, $nonexistent_session_id, 'Test reason');

    # Should fail with appropriate error
    ok $result->{error}, 'Transfer to nonexistent session rejected';
    like $result->{error}, qr/Target session not found/, 'Appropriate error message for nonexistent session';
};

subtest 'Transfer Request Denial' => sub {
    my $setup = setup_test_data('denial');

    # Test transfer request denial
    my $transfer_family_member = $dao->create(FamilyMember => {
        family_id => $setup->{parent_user}->id,
        child_name => 'Transfer Child',
        birth_date => '2010-01-01',
        grade => '8th'
    });

    my $transfer_enrollment = $dao->create(Enrollment => {
        session_id => $setup->{future_session}->id,
        student_id => $transfer_family_member->id,
        family_member_id => $transfer_family_member->id,
        parent_id => $setup->{parent_user}->id,
        status => 'active'
    });

    my $transfer_result = $transfer_enrollment->request_transfer($dao->db, $setup->{parent_user}, $setup->{target_session}->id, 'Want different schedule');
    my $transfer_request = $transfer_result->{transfer_request};

    # Admin denies the transfer
    $transfer_request->deny($dao->db, $setup->{admin_user}, 'Target session conflicts with student schedule');

    # Check enrollment remains in original session
    my $updated_transfer_enrollment = Registry::DAO::Enrollment->find($dao->db, { id => $transfer_enrollment->id });
    is $updated_transfer_enrollment->session_id, $setup->{future_session}->id, 'Enrollment remains in original session after transfer denial';
    is $updated_transfer_enrollment->transfer_status, 'none', 'Transfer status reset after denial';

    my $updated_transfer_request = Registry::DAO::TransferRequest->find($dao->db, { id => $transfer_request->id });
    is $updated_transfer_request->status, 'denied', 'Transfer request marked as denied';
};

subtest 'Permission Checks' => sub {
    my $setup = setup_test_data('permissions');

    # Create another parent user
    my $other_parent = $dao->create(User => {
        username => 'other_parent_permissions',
        user_type => 'parent',
        email => 'other_permissions@test.com',
        name => 'Other Parent'
    });

    # Create enrollment
    my $enrollment = $dao->create(Enrollment => {
        session_id => $setup->{future_session}->id,
        student_id => $setup->{family_member}->id,
        family_member_id => $setup->{family_member}->id,
        parent_id => $setup->{parent_user}->id,
        status => 'active'
    });

    # Test permissions for transfers (drop permissions not yet implemented)
    ok $enrollment->can_transfer($dao->db, $setup->{admin_user}), 'Admin can transfer enrollments';
    ok $enrollment->can_transfer($dao->db, $setup->{parent_user}), 'Parent can request transfers for their children';
    ok !$enrollment->can_transfer($dao->db, $other_parent), 'Other parent cannot request transfers';
};

subtest 'Multiple Transfer Requests Edge Cases' => sub {
    my $setup = setup_test_data('multiple');

    # Test multiple transfer requests
    my $transfer_family_member = $dao->create(FamilyMember => {
        family_id => $setup->{parent_user}->id,
        child_name => 'Multi Transfer Child',
        birth_date => '2010-01-01',
        grade => '8th'
    });

    my $transfer_enrollment = $dao->create(Enrollment => {
        session_id => $setup->{future_session}->id,
        student_id => $transfer_family_member->id,
        family_member_id => $transfer_family_member->id,
        parent_id => $setup->{parent_user}->id,
        status => 'active'
    });

    # Request transfer
    my $transfer_result = $transfer_enrollment->request_transfer($dao->db, $setup->{parent_user}, $setup->{target_session}->id, 'First transfer');
    ok $transfer_result->{success}, 'First transfer request succeeds';

    # Attempt second transfer while first is pending
    my $second_transfer_result = $transfer_enrollment->request_transfer($dao->db, $setup->{parent_user}, $setup->{full_session}->id, 'Second transfer');
    ok $second_transfer_result->{error}, 'Second transfer request fails while first is pending';
    like $second_transfer_result->{error}, qr/already has a pending transfer request/, 'Appropriate error for duplicate transfer request';
};