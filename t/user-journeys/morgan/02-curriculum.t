use 5.40.2;
use lib          qw(lib t/lib);
use experimental qw(defer builtin);

use Test::Mojo;
use Test::More import => [qw( done_testing is ok diag subtest )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;

# ABOUTME: Test Morgan's curriculum development user journey workflow
# ABOUTME: Validates curriculum creation, organization, and sharing flows

my $t    = Test::Mojo->new('Registry');
my $db   = Test::Registry::DB->load;
my $dao  = Registry::DAO->new( db => $db );

# Create test admin user (Morgan persona)
my $morgan = $dao->user->create( $db, {
    username   => 'morgan_curriculum',
    password   => 'test_password123',
    email      => 'morgan.curr@example.org',
    first_name => 'Morgan',
    last_name  => 'Curriculum',
    metadata   => { role => 'admin' }
});

# Test: Create new curriculum materials
subtest 'Create new curriculum materials' => sub {
    # Login as Morgan
    $t->post_ok('/login', form => {
        username => 'morgan_curriculum',
        password => 'test_password123'
    })->status_is(302);

    # Navigate to curriculum management
    $t->get_ok('/admin/curriculum')
      ->status_is(200)
      ->text_is('h1', 'Curriculum Management')
      ->element_exists('a[href="/admin/curriculum/new"]');

    # Create new curriculum
    $t->get_ok('/admin/curriculum/new')
      ->status_is(200)
      ->text_is('h2', 'Create New Curriculum')
      ->element_exists('form#curriculum-form');

    # Submit curriculum details
    $t->post_ok('/admin/curriculum/new', form => {
        name        => 'Introduction to Python Programming',
        description => 'Learn Python basics for beginners',
        subject     => 'computer_science',
        grade_level => '6-8',
        duration    => '12 weeks',
        materials   => 'Laptop, Python installed, workbook'
    })->status_is(200)
      ->text_like('.success', qr/Curriculum created successfully/);

    # Verify curriculum was created
    my $curriculum = $dao->curriculum->find( $db, {
        name => 'Introduction to Python Programming'
    });
    ok $curriculum, 'Curriculum exists in database';
    is $curriculum->metadata->{subject}, 'computer_science', 'Subject is correct';
};

# Test: Organize materials into structured lessons
subtest 'Organize materials into structured lessons' => sub {
    my $curriculum = $dao->curriculum->find( $db, {
        name => 'Introduction to Python Programming'
    });

    # Navigate to lesson organization
    $t->get_ok("/admin/curriculum/" . $curriculum->id . "/lessons")
      ->status_is(200)
      ->text_is('h2', 'Organize Lessons')
      ->element_exists('button#add-lesson');

    # Add first lesson
    $t->post_ok("/admin/curriculum/" . $curriculum->id . "/lessons", form => {
        title       => 'Introduction and Setup',
        week        => 1,
        objectives  => 'Install Python, understand basic syntax',
        activities  => 'Installation walkthrough, Hello World program',
        assessment  => 'Complete setup verification quiz',
        duration    => '90 minutes'
    })->status_is(200)
      ->text_like('.success', qr/Lesson added successfully/);

    # Add second lesson
    $t->post_ok("/admin/curriculum/" . $curriculum->id . "/lessons", form => {
        title       => 'Variables and Data Types',
        week        => 2,
        objectives  => 'Understand variables, strings, numbers',
        activities  => 'Variable exercises, type conversion practice',
        assessment  => 'Data types worksheet',
        duration    => '90 minutes'
    })->status_is(200)
      ->text_like('.success', qr/Lesson added successfully/);

    # Verify lessons
    my $lessons = $curriculum->lessons($db);
    is scalar(@$lessons), 2, 'Two lessons created';
    is $lessons->[0]->{title}, 'Introduction and Setup', 'First lesson correct';
};

# Test: Link materials to educational standards
subtest 'Link materials to educational standards' => sub {
    my $curriculum = $dao->curriculum->find( $db, {
        name => 'Introduction to Python Programming'
    });

    # Navigate to standards alignment
    $t->get_ok("/admin/curriculum/" . $curriculum->id . "/standards")
      ->status_is(200)
      ->text_is('h2', 'Educational Standards Alignment')
      ->element_exists('select#standard-framework');

    # Link to NGSS standards
    $t->post_ok("/admin/curriculum/" . $curriculum->id . "/standards", form => {
        framework   => 'NGSS',
        standard_id => 'MS-ETS1-1',
        description => 'Define criteria and constraints of a design problem',
        alignment   => 'primary'
    })->status_is(200)
      ->text_like('.success', qr/Standard linked successfully/);

    # Link to Common Core standards
    $t->post_ok("/admin/curriculum/" . $curriculum->id . "/standards", form => {
        framework   => 'CommonCore',
        standard_id => 'CCSS.MATH.PRACTICE.MP1',
        description => 'Make sense of problems and persevere',
        alignment   => 'supporting'
    })->status_is(200)
      ->text_like('.success', qr/Standard linked successfully/);

    # Verify standards alignment
    my $standards = $curriculum->standards($db);
    is scalar(@$standards), 2, 'Two standards linked';
    ok grep({ $_->{framework} eq 'NGSS' } @$standards), 'NGSS standard linked';
};

# Test: Share materials with teaching staff
subtest 'Share materials with teaching staff' => sub {
    # Create test teacher
    my $teacher = $dao->user->create( $db, {
        username   => 'teacher_jones',
        password   => 'password123',
        email      => 'jones@example.org',
        first_name => 'Bob',
        last_name  => 'Jones',
        metadata   => { role => 'teacher' }
    });

    my $curriculum = $dao->curriculum->find( $db, {
        name => 'Introduction to Python Programming'
    });

    # Navigate to sharing settings
    $t->get_ok("/admin/curriculum/" . $curriculum->id . "/sharing")
      ->status_is(200)
      ->text_is('h2', 'Share Curriculum')
      ->element_exists('input#teacher-search');

    # Share with specific teacher
    $t->post_ok("/admin/curriculum/" . $curriculum->id . "/share", form => {
        teacher_id   => $teacher->id,
        permission   => 'view_edit',
        notify_email => 1
    })->status_is(200)
      ->text_like('.success', qr/Curriculum shared with Bob Jones/);

    # Share with all teachers in a program
    my $program = $dao->program->create( $db, {
        name => 'Summer Python Camp',
        slug => 'summer-python-camp'
    });

    $t->post_ok("/admin/curriculum/" . $curriculum->id . "/share-program", form => {
        program_id => $program->id,
        permission => 'view_only'
    })->status_is(200)
      ->text_like('.success', qr/Curriculum shared with program/);

    # Verify sharing
    my $shares = $curriculum->shared_with($db);
    ok scalar(@$shares) >= 1, 'Curriculum is shared';
    ok grep({ $_->{user_id} eq $teacher->id } @$shares), 'Shared with teacher';
};

# Test curriculum versioning
subtest 'Curriculum versioning and updates' => sub {
    my $curriculum = $dao->curriculum->find( $db, {
        name => 'Introduction to Python Programming'
    });

    # Create new version
    $t->get_ok("/admin/curriculum/" . $curriculum->id . "/version")
      ->status_is(200)
      ->text_is('h2', 'Create New Version');

    $t->post_ok("/admin/curriculum/" . $curriculum->id . "/version", form => {
        version_notes => 'Updated for Python 3.12, added AI/ML examples',
        major_version => 2,
        minor_version => 0
    })->status_is(200)
      ->text_like('.success', qr/New version created/);

    # Verify version
    my $versions = $curriculum->versions($db);
    ok scalar(@$versions) >= 1, 'Version history exists';
};

# Test curriculum resources and attachments
subtest 'Add resources and attachments' => sub {
    my $curriculum = $dao->curriculum->find( $db, {
        name => 'Introduction to Python Programming'
    });

    # Navigate to resources
    $t->get_ok("/admin/curriculum/" . $curriculum->id . "/resources")
      ->status_is(200)
      ->text_is('h2', 'Curriculum Resources')
      ->element_exists('button#add-resource');

    # Add resource link
    $t->post_ok("/admin/curriculum/" . $curriculum->id . "/resources", form => {
        type        => 'link',
        title       => 'Python Official Tutorial',
        url         => 'https://docs.python.org/3/tutorial/',
        description => 'Official Python documentation tutorial'
    })->status_is(200)
      ->text_like('.success', qr/Resource added/);

    # Add document resource
    $t->post_ok("/admin/curriculum/" . $curriculum->id . "/resources", form => {
        type        => 'document',
        title       => 'Student Workbook',
        description => 'Printable workbook for exercises',
        file_path   => '/resources/python-workbook.pdf'
    })->status_is(200)
      ->text_like('.success', qr/Resource added/);

    # Verify resources
    my $resources = $curriculum->resources($db);
    is scalar(@$resources), 2, 'Two resources added';
};