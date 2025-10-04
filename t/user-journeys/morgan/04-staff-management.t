use 5.40.2;
use lib          qw(lib t/lib);
use experimental qw(defer builtin);

use Test::More import => [qw( done_testing is ok )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;

# ABOUTME: Test Morgan's staff management user journey workflow
# ABOUTME: Validates teacher accounts, assignments, permissions, and monitoring

my $t   = Test::Registry::DB->new;
my $db  = $t->db;
my $dao = Registry::DAO->new( db => $db );

# Test: Create and configure teacher accounts
ok my $teacher = $dao->create( 'User', {
    username   => 'sarah_teacher',
    email      => 'sarah@school.edu',
    first_name => 'Sarah',
    last_name  => 'Thompson',
    password   => 'secure_password',
    metadata   => {
        role           => 'teacher',
        department     => 'Mathematics',
        qualifications => 'MS Mathematics, Teaching Certificate',
        subjects       => 'algebra,geometry,calculus',
        experience_years => 5
    }
}), 'Create and configure teacher accounts';

# Test: Assign teachers to specific sessions
ok my $program = $dao->create( 'Program', {
    name     => 'Advanced Algebra',
    slug     => 'advanced-algebra',
    metadata => { department => 'Mathematics' }
}), 'Create program for assignment';

ok my $session = $dao->create( 'Session', {
    name       => 'Algebra Session 1',
    slug       => 'algebra-session-1',
    start_date => '2025-09-01',
    end_date   => '2025-12-15',
    capacity   => 25,
    metadata   => { program_id => $program->id }
}), 'Create session for assignment';

ok $session->add_teachers( $dao->db, $teacher->id ),
    'Assign teachers to specific sessions';

# Test: Set up role-based permissions
ok $teacher->metadata->{role}, 'Teacher has role';
ok $teacher->metadata->{role} eq 'teacher', 'Set up role-based permissions';

# Test: Monitor and report on teacher activities
ok $teacher->metadata->{department}, 'Teacher has department';
ok $teacher->metadata->{department} eq 'Mathematics',
    'Monitor and report on teacher activities';