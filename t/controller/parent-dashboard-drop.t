use 5.40.2;
use lib          qw(lib t/lib);
use experimental qw(defer builtin);

use Test::More import => [qw( done_testing is ok fail subtest diag )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;
use Test::Mojo;

my $test_db = Test::Registry::DB->new();
my $dao = $test_db->db;
my $t = Test::Mojo->new('Registry');

# Set up test data
my $parent_user = $dao->create(User => {
    username => 'test_parent_controller',
    user_type => 'parent',
    email => 'parent@test.com',
    name => 'Test Parent'
});

my $family_member = $dao->create(FamilyMember => {
    family_id => $parent_user->id,
    child_name => 'Test Child',
    birth_date => '2010-01-01',
    grade => '8th'
});

subtest 'Parent can drop enrollment before session starts' => sub {
    # Create future session
    my $future_session = $dao->create(Session => {
        name => 'Future Controller Test Session',
        start_date => '2025-12-01',
        end_date => '2025-12-15'
    });

    # Create enrollment
    my $enrollment = $dao->create(Enrollment => {
        session_id => $future_session->id,
        student_id => $family_member->id,
        family_member_id => $family_member->id,
        parent_id => $parent_user->id,
        status => 'active'
    });

    # Mock authenticated user in stash
    $t->app->hook(before_dispatch => sub {
        my $c = shift;
        $c->stash(current_user => {
            id => $parent_user->id,
            user_type => 'parent',
            role => 'parent'
        });
        $c->stash(tenant => 'registry');
    });

    # Test immediate drop via POST
    my $response = $t->post_ok('/parent/dashboard/drop_enrollment' => form => {
        enrollment_id => $enrollment->id,
        reason => 'Parent requested drop'
    });

    # Debug the response
    if ($response->tx->res->code != 200) {
        diag "Response status: " . $response->tx->res->code;
        diag "Response body: " . $response->tx->res->body;
    }

    $response->status_is(200);

    # Verify enrollment was cancelled
    my $updated_enrollment = Registry::DAO::Enrollment->find($dao->db, { id => $enrollment->id });
    is $updated_enrollment->status, 'cancelled', 'Enrollment status updated to cancelled';
    ok defined $updated_enrollment->drop_reason, 'Drop reason was recorded';
};

subtest 'Parent creates drop request for started session' => sub {
    # Create past session (already started)
    my $started_session = $dao->create(Session => {
        name => 'Started Controller Test Session',
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

    # Test drop request creation
    $t->post_ok('/parent/dashboard/drop_enrollment' => form => {
        enrollment_id => $enrollment->id,
        reason => 'Family emergency',
        refund_requested => 1
    })->status_is(200);

    # Verify enrollment is still active (not immediately cancelled)
    my $updated_enrollment = Registry::DAO::Enrollment->find($dao->db, { id => $enrollment->id });
    is $updated_enrollment->status, 'active', 'Enrollment remains active pending admin approval';

    # Verify drop request was created
    my @drop_requests = Registry::DAO::DropRequest->find($dao->db, {
        enrollment_id => $enrollment->id
    });
    ok @drop_requests > 0, 'Drop request was created';
    is $drop_requests[0]->status, 'pending', 'Drop request has pending status';
    is $drop_requests[0]->reason, 'Family emergency', 'Drop reason recorded correctly';
    is $drop_requests[0]->refund_requested, 1, 'Refund request recorded correctly';
};