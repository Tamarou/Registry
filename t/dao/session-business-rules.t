use 5.40.2;
use lib          qw(lib t/lib);
use experimental qw(defer builtin);

use Test::More import => [qw( done_testing is ok fail subtest )];
use Test::Exception;
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;

my $test_db = Test::Registry::DB->new();
my $dao = $test_db->db;

subtest 'Session has_started method' => sub {
    # Test session that hasn't started yet
    my $future_session = $dao->create(Session => {
        name => 'Future Session',
        start_date => '2025-12-01',
        end_date => '2025-12-15'
    });

    ok !$future_session->has_started(),
        'Session with future start date has not started';

    # Test session that started today
    my $today = sprintf('%04d-%02d-%02d',
        (localtime)[5] + 1900, (localtime)[4] + 1, (localtime)[3]);

    my $today_session = $dao->create(Session => {
        name => 'Today Session',
        start_date => $today,
        end_date => '2025-12-15'
    });

    ok $today_session->has_started(),
        'Session starting today has started';

    # Test session that started in the past
    my $past_session = $dao->create(Session => {
        name => 'Past Session',
        start_date => '2020-01-01',
        end_date => '2020-01-15'
    });

    ok $past_session->has_started(),
        'Session with past start date has started';

    # Test session with no start date
    my $no_date_session = $dao->create(Session => {
        name => 'No Date Session',
        end_date => '2025-12-15'
    });

    ok !$no_date_session->has_started(),
        'Session with no start date has not started';
};

subtest 'Enrollment drop permission checks' => sub {
    # Create test user and admin
    my $parent_user = $dao->create(User => {
        username => 'test_parent',
        role => 'parent'
    });

    my $admin_user = $dao->create(User => {
        username => 'admin_user',
        role => 'admin'
    });

    # Create session that hasn't started
    my $future_session = $dao->create(Session => {
        name => 'Future Drop Test Session',
        start_date => '2025-12-01',
        end_date => '2025-12-15'
    });

    # Create enrollment
    my $future_enrollment = $dao->create(Enrollment => {
        session_id => $future_session->id,
        student_id => $parent_user->id,
        parent_id => $parent_user->id,
        status => 'active'
    });

    ok $future_enrollment->can_drop($dao->db, { role => 'parent' }),
        'Parent can drop enrollment before session starts';

    ok $future_enrollment->can_drop($dao->db, { role => 'admin' }),
        'Admin can drop enrollment before session starts';

    # Create session that has started
    my $past_session = $dao->create(Session => {
        name => 'Started Drop Test Session',
        start_date => '2020-01-01',
        end_date => '2020-01-15'
    });

    my $started_enrollment = $dao->create(Enrollment => {
        session_id => $past_session->id,
        student_id => $parent_user->id,
        parent_id => $parent_user->id,
        status => 'active'
    });

    ok !$started_enrollment->can_drop($dao->db, { role => 'parent' }),
        'Parent cannot drop enrollment after session starts';

    ok $started_enrollment->can_drop($dao->db, { role => 'admin' }),
        'Admin can drop enrollment after session starts';
};

subtest 'Drop request creation for post-start sessions' => sub {
    # Create test parent
    my $parent = $dao->create(User => {
        username => 'drop_request_parent',
        role => 'parent'
    });

    # Create started session
    my $started_session = $dao->create(Session => {
        name => 'Drop Request Session',
        start_date => '2020-01-01',
        end_date => '2020-01-15'
    });

    my $enrollment = $dao->create(Enrollment => {
        session_id => $started_session->id,
        student_id => $parent->id,
        parent_id => $parent->id,
        status => 'active'
    });

    # Parent requests drop after session starts
    my $drop_request = $enrollment->request_drop($dao->db, $parent,
        'Family emergency', 1);  # 1 = refund requested

    ok defined $drop_request, 'Drop request created successfully';
    is $drop_request->status, 'pending', 'Drop request has pending status';
    is $drop_request->refund_requested, 1, 'Refund was requested';
    is $drop_request->reason, 'Family emergency', 'Reason stored correctly';
};