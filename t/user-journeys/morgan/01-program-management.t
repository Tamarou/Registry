use 5.40.2;
use lib          qw(lib t/lib);
use experimental qw(defer builtin);

use Test::More import => [qw( done_testing is ok )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;

# ABOUTME: Test Morgan's program management user journey workflow
# ABOUTME: Validates complete program creation, update, and management flows

my $t   = Test::Registry::DB->new;
my $db  = $t->db;
my $dao = Registry::DAO->new( db => $db );

# Test: Create new educational program with curriculum and schedule
ok my $program = $dao->create( 'Program', {
    name        => 'Advanced Robotics',
    description => 'Learn robotics and programming',
    metadata    => {
        type     => 'stem',
        age_min  => 10,
        age_max  => 14,
        capacity => 20,
        price    => 299.99
    }
}), 'Create new educational program with curriculum and schedule';

# Test: Update existing program details
ok $program->update($dao->db, {
    name => 'Advanced Robotics Plus',
    metadata => {
        %{$program->metadata},
        capacity => 25
    }
}), 'Update existing program details';

# Test: Assign teachers to program
ok my $teacher = $dao->create( 'User', {
    username   => 'teacher_smith',
    password   => 'password123',
    email      => 'smith@example.org',
    name       => 'Jane Smith',
    user_type  => 'staff'
}), 'Create teacher account';

ok $program->add_teachers( $dao->db, $teacher->id ), 'Assign teachers to program';

# Test: Set and modify program schedule
ok $program->set_schedule($dao->db, {
    start_date  => '2025-06-01',
    end_date    => '2025-08-31',
    days        => 'monday,wednesday,friday',
    start_time  => '14:00',
    end_time    => '16:00',
    location_id => 1
}), 'Set and modify program schedule';