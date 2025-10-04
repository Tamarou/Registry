use 5.40.2;
use lib          qw(lib t/lib);
use experimental qw(defer builtin);

use Test::More import => [qw( done_testing is ok )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;

# ABOUTME: Test Morgan's curriculum development user journey workflow
# ABOUTME: Validates curriculum creation, organization, and sharing flows

my $t   = Test::Registry::DB->new;
my $db  = $t->db;
my $dao = Registry::DAO->new( db => $db );

# Test: Create new curriculum materials
ok my $curriculum = $dao->create( 'Curriculum', {
    name        => 'Introduction to Python Programming',
    description => 'Learn Python basics for beginners',
    metadata    => {
        subject     => 'computer_science',
        grade_level => '6-8',
        duration    => '12 weeks',
        materials   => 'Laptop, Python installed, workbook'
    }
}), 'Create new curriculum materials';

# Test: Organize materials into structured lessons
ok $curriculum->add_lesson($dao->db, {
    title      => 'Introduction and Setup',
    week       => 1,
    objectives => 'Install Python, understand basic syntax',
    activities => 'Installation walkthrough, Hello World program',
    assessment => 'Complete setup verification quiz',
    duration   => '90 minutes'
}), 'Organize materials into structured lessons';

# Test: Link materials to educational standards
ok $curriculum->add_standard($dao->db, {
    framework   => 'NGSS',
    standard_id => 'MS-ETS1-1',
    description => 'Define criteria and constraints of a design problem',
    alignment   => 'primary'
}), 'Link materials to educational standards';

# Test: Share materials with teaching staff
ok my $teacher = $dao->create( 'User', {
    username   => 'teacher_jones',
    password   => 'password123',
    email      => 'jones@example.org',
    first_name => 'Bob',
    last_name  => 'Jones',
    metadata   => { role => 'teacher' }
}), 'Create teacher for sharing';

ok $curriculum->share_with($dao->db, $teacher->id, 'view_edit'),
    'Share materials with teaching staff';