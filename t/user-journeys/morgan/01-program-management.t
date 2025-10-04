use 5.40.2;
use lib          qw(lib t/lib);
use experimental qw(defer builtin);

use Test::Mojo;
use Test::More import => [qw( done_testing is ok diag subtest )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;

# ABOUTME: Test Morgan's program management user journey workflow
# ABOUTME: Validates complete program creation, update, and management flows

my $t    = Test::Mojo->new('Registry');
my $db   = Test::Registry::DB->load;
my $dao  = Registry::DAO->new( db => $db );

# Create test admin user (Morgan persona)
my $morgan = $dao->create( 'User', {
    username   => 'morgan_admin',
    password   => 'test_password123',
    email      => 'morgan@example.org',
    first_name => 'Morgan',
    last_name  => 'Administrator',
    metadata   => { role => 'admin' }
});

# Test: Create new educational program with curriculum and schedule
subtest 'Create new educational program' => sub {
    # Login as Morgan
    $t->post_ok('/login', form => {
        username => 'morgan_admin',
        password => 'test_password123'
    })->status_is(302);

    # Navigate to program management
    $t->get_ok('/admin/programs')
      ->status_is(200)
      ->text_is('h1', 'Program Management')
      ->element_exists('a[href="/admin/programs/new"]', 'Has create program link');

    # Start program creation workflow
    $t->get_ok('/admin/programs/new')
      ->status_is(200)
      ->text_is('h2', 'Create New Program')
      ->element_exists('form#program-form');

    # Submit program details
    $t->post_ok('/admin/programs/new', form => {
        name        => 'Advanced Robotics',
        description => 'Learn robotics and programming',
        type        => 'stem',
        age_min     => 10,
        age_max     => 14,
        capacity    => 20,
        price       => 299.99
    })->status_is(200)
      ->text_like('.success', qr/Program created successfully/);

    # Verify program was created
    my $program = $dao->find( 'Program', { name => 'Advanced Robotics' } );
    ok $program, 'Program exists in database';
    is $program->metadata->{type}, 'stem', 'Program type is correct';
};

# Test: Update existing program details
subtest 'Update existing program' => sub {
    # Get the created program
    my $program = $dao->find( 'Program', { name => 'Advanced Robotics' } );

    # Navigate to program edit page
    $t->get_ok("/admin/programs/" . $program->id . "/edit")
      ->status_is(200)
      ->text_is('h2', 'Edit Program: Advanced Robotics');

    # Update program details
    $t->post_ok("/admin/programs/" . $program->id . "/edit", form => {
        name        => 'Advanced Robotics Plus',
        description => 'Learn advanced robotics and AI programming',
        capacity    => 25,
        price       => 349.99
    })->status_is(200)
      ->text_like('.success', qr/Program updated successfully/);

    # Verify updates
    my $updated = $dao->find( 'Program', { id => $program->id } );
    is $updated->name, 'Advanced Robotics Plus', 'Program name updated';
    is $updated->metadata->{capacity}, 25, 'Capacity updated';
};

# Test: Assign teachers to program
subtest 'Assign teachers to program' => sub {
    # Create test teacher
    my $teacher = $dao->create( 'User', {
        username   => 'teacher_smith',
        password   => 'password123',
        email      => 'smith@example.org',
        first_name => 'Jane',
        last_name  => 'Smith',
        metadata   => { role => 'teacher' }
    });

    my $program = $dao->find( 'Program', { name => 'Advanced Robotics Plus' } );

    # Navigate to teacher assignment
    $t->get_ok("/admin/programs/" . $program->id . "/teachers")
      ->status_is(200)
      ->text_is('h2', 'Manage Teachers: Advanced Robotics Plus')
      ->element_exists('select#teacher-select');

    # Assign teacher
    $t->post_ok("/admin/programs/" . $program->id . "/teachers", form => {
        teacher_id => $teacher->id,
        role       => 'lead_instructor'
    })->status_is(200)
      ->text_like('.success', qr/Teacher assigned successfully/);

    # Verify assignment
    my $assignments = $dao->find( 'ProgramTeacher', {
        program_id => $program->id,
        teacher_id => $teacher->id
    });
    ok $assignments, 'Teacher assigned to program';
};

# Test: Set and modify program schedule
subtest 'Set and modify program schedule' => sub {
    my $program = $dao->find( 'Program', { name => 'Advanced Robotics Plus' } );

    # Navigate to schedule management
    $t->get_ok("/admin/programs/" . $program->id . "/schedule")
      ->status_is(200)
      ->text_is('h2', 'Program Schedule: Advanced Robotics Plus')
      ->element_exists('form#schedule-form');

    # Create initial schedule
    $t->post_ok("/admin/programs/" . $program->id . "/schedule", form => {
        start_date  => '2025-06-01',
        end_date    => '2025-08-31',
        days        => 'monday,wednesday,friday',
        start_time  => '14:00',
        end_time    => '16:00',
        location_id => 1  # Assuming a test location exists
    })->status_is(200)
      ->text_like('.success', qr/Schedule created successfully/);

    # Modify schedule
    $t->post_ok("/admin/programs/" . $program->id . "/schedule/update", form => {
        start_time => '15:00',
        end_time   => '17:00'
    })->status_is(200)
      ->text_like('.success', qr/Schedule updated successfully/);

    # Verify schedule exists
    my $schedule = $program->schedule($db);
    ok $schedule, 'Program has schedule';
    is $schedule->{start_time}, '15:00', 'Schedule time updated';
};

# Test program lifecycle management
subtest 'Program lifecycle management' => sub {
    my $program = $dao->find( 'Program', { name => 'Advanced Robotics Plus' } );

    # Test program status transitions
    $t->get_ok("/admin/programs/" . $program->id)
      ->status_is(200)
      ->text_is('h2', 'Advanced Robotics Plus')
      ->element_exists('button[name="publish"]', 'Has publish button');

    # Publish program
    $t->post_ok("/admin/programs/" . $program->id . "/publish")
      ->status_is(200)
      ->text_like('.success', qr/Program published/);

    # Archive program
    $t->post_ok("/admin/programs/" . $program->id . "/archive")
      ->status_is(200)
      ->text_like('.success', qr/Program archived/);

    # Verify status
    my $archived = $dao->find( 'Program', { id => $program->id } );
    is $archived->status, 'archived', 'Program is archived';
};

# Test program cloning functionality
subtest 'Clone existing program' => sub {
    my $original = $dao->find( 'Program', { name => 'Advanced Robotics Plus' } );

    $t->get_ok("/admin/programs/" . $original->id . "/clone")
      ->status_is(200)
      ->text_is('h2', 'Clone Program: Advanced Robotics Plus');

    $t->post_ok("/admin/programs/" . $original->id . "/clone", form => {
        name       => 'Advanced Robotics Summer 2025',
        start_date => '2025-06-15',
        end_date   => '2025-08-15'
    })->status_is(200)
      ->text_like('.success', qr/Program cloned successfully/);

    # Verify clone
    my $clone = $dao->find( 'Program', { name => 'Advanced Robotics Summer 2025' } );
    ok $clone, 'Cloned program exists';
    is $clone->metadata->{type}, 'stem', 'Clone has same type as original';
};