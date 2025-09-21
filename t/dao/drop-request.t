use 5.40.2;
use lib          qw(lib t/lib);
use experimental qw(defer builtin);

use Test::More import => [qw( done_testing is ok fail subtest )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;

my $test_db = Test::Registry::DB->new();
my $dao = $test_db->db;

# Import the workflows that DropRequest DAO depends on
use Mojo::File qw(path);
my @workflow_files = path('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;
$dao->import_workflows(\@workflow_files); # Uses the new DAO helper method

subtest 'Admin drop request workflow' => sub {
    # Create test users
    my $parent_user = $dao->create(User => {
        username => 'admin_test_parent',
        user_type => 'parent',
        email => 'parent@admin-test.com',
        name => 'Test Parent'
    });

    my $admin_user = $dao->create(User => {
        username => 'admin_test_admin',
        user_type => 'admin',
        email => 'admin@admin-test.com',
        name => 'Test Admin'
    });

    my $family_member = $dao->create(FamilyMember => {
        family_id => $parent_user->id,
        child_name => 'Admin Test Child',
        birth_date => '2010-01-01',
        grade => '8th'
    });

    # Create session that has started
    my $started_session = $dao->create(Session => {
        name => 'Admin Started Session',
        start_date => '2020-01-01',
        end_date => '2020-01-15'
    });

    # Create enrollment
    my $enrollment = $dao->create(Enrollment => {
        session_id => $started_session->id,
        student_id => $family_member->id,
        family_member_id => $family_member->id,
        parent_id => $parent_user->id,
        status => 'active'
    });

    # Parent creates drop request (would happen via ParentDashboard)
    my $drop_request = $enrollment->request_drop($dao->db, $parent_user,
        'Administrative test drop', 1);

    # Verify drop request was created
    ok defined $drop_request, 'Drop request created successfully';
    is $drop_request->status, 'pending', 'Drop request has pending status';

    # Test admin approval
    $drop_request->approve($dao->db, $admin_user, 'Approved for testing', 50.00);

    # Verify request was processed
    my $updated_request = Registry::DAO::DropRequest->find($dao->db, { id => $drop_request->id });
    is $updated_request->status, 'approved', 'Drop request was approved';
    is $updated_request->admin_notes, 'Approved for testing', 'Admin notes recorded';

    # Verify enrollment was cancelled
    my $updated_enrollment = Registry::DAO::Enrollment->find($dao->db, { id => $enrollment->id });
    is $updated_enrollment->status, 'cancelled', 'Enrollment was cancelled';
    is $updated_enrollment->drop_reason, 'Administrative test drop', 'Drop reason recorded';
    ok defined $updated_enrollment->dropped_at, 'Drop timestamp recorded';
    is $updated_enrollment->dropped_by, $admin_user->id, 'Admin who processed drop recorded';
    is $updated_enrollment->refund_status, 'pending', 'Refund status set to pending';
    is $updated_enrollment->refund_amount, '50.00', 'Refund amount recorded';
};

subtest 'Admin drop request denial workflow' => sub {
    # Create test data
    my $parent_user = $dao->create(User => {
        username => 'admin_deny_parent',
        user_type => 'parent',
        email => 'parent@deny-test.com',
        name => 'Deny Test Parent'
    });

    my $admin_user = $dao->create(User => {
        username => 'admin_deny_admin',
        user_type => 'admin',
        email => 'admin@deny-test.com',
        name => 'Deny Test Admin'
    });

    my $family_member = $dao->create(FamilyMember => {
        family_id => $parent_user->id,
        child_name => 'Deny Test Child',
        birth_date => '2010-01-01',
        grade => '8th'
    });

    # Create session that has started
    my $started_session = $dao->create(Session => {
        name => 'Admin Deny Session',
        start_date => '2020-01-01',
        end_date => '2020-01-15'
    });

    # Create enrollment
    my $enrollment = $dao->create(Enrollment => {
        session_id => $started_session->id,
        student_id => $family_member->id,
        family_member_id => $family_member->id,
        parent_id => $parent_user->id,
        status => 'active'
    });

    # Parent creates drop request
    my $drop_request = $enrollment->request_drop($dao->db, $parent_user,
        'Request to be denied', 1);

    # Test admin denial
    $drop_request->deny($dao->db, $admin_user, 'Session has already started and curriculum cannot be repeated');

    # Verify request was denied
    my $updated_request = Registry::DAO::DropRequest->find($dao->db, { id => $drop_request->id });
    is $updated_request->status, 'denied', 'Drop request was denied';
    is $updated_request->admin_notes, 'Session has already started and curriculum cannot be repeated', 'Denial reason recorded';

    # Verify enrollment remains active
    my $updated_enrollment = Registry::DAO::Enrollment->find($dao->db, { id => $enrollment->id });
    is $updated_enrollment->status, 'active', 'Enrollment remains active after denial';
    ok !defined $updated_enrollment->drop_reason, 'No drop reason recorded for denied request';
};

subtest 'Get drop requests helper method' => sub {
    # Test that the helper method returns properly formatted data
    # Note: This would normally require a full app setup to test the controller method
    # For now, we'll test the DAO functionality directly

    # Create a pending request for the test
    my $parent_user = $dao->create(User => {
        username => 'helper_test_parent',
        user_type => 'parent',
        email => 'parent@helper-test.com',
        name => 'Helper Test Parent'
    });

    my $family_member = $dao->create(FamilyMember => {
        family_id => $parent_user->id,
        child_name => 'Helper Test Child',
        birth_date => '2010-01-01',
        grade => '8th'
    });

    my $session = $dao->create(Session => {
        name => 'Helper Test Session',
        start_date => '2020-01-01',
        end_date => '2020-01-15'
    });

    my $enrollment = $dao->create(Enrollment => {
        session_id => $session->id,
        student_id => $family_member->id,
        family_member_id => $family_member->id,
        parent_id => $parent_user->id,
        status => 'active'
    });

    my $drop_request = $enrollment->request_drop($dao->db, $parent_user,
        'Helper method test', 0);

    # Get pending drop requests
    my $pending_requests = Registry::DAO::DropRequest->get_pending($dao->db);
    ok @$pending_requests > 0, 'Found pending drop requests';

    my $found_request = (grep { $_->id eq $drop_request->id } @$pending_requests)[0];
    ok defined $found_request, 'Our test request was found in pending list';
    is $found_request->status, 'pending', 'Request has correct status';
};