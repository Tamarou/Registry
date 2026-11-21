# ABOUTME: Morgan (program administrator) user journey test for staff management.
# ABOUTME: Creates staff accounts via the user-creation workflow and assigns them to sessions.
use 5.42.0;
use lib          qw(lib t/lib);
use experimental qw(defer);

use Test::Registry::Mojo;
use Mojo::Home;
use Test::More import => [qw( done_testing is ok )];
defer { done_testing };

use Registry::DAO           qw(Workflow);
use Test::Registry::DB      ();
use Test::Registry::Helpers qw(
  workflow_url
  workflow_run_step_url
  workflow_process_step_url
);
use YAML::XS qw(Load);

my $test_db = Test::Registry::DB->new();
my $dao     = $test_db->db;

$ENV{DB_URL} = $test_db->uri;

# Import all non-draft workflows
my @files =
  Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;
for my $file (@files) {
    next if Load( $file->slurp )->{draft};
    Workflow->from_yaml( $dao, $file->slurp );
}

# Prerequisite session to assign staff to
my $location = $dao->create( Location => { name => 'School Gym' } );
my $project  = $dao->create( Project  => { name => 'Robotics Club' } );
my $session  = $dao->create(
    Session => {
        name       => 'Robotics Fall 2024',
        project_id => $project->id,
    }
);

{    # Journey: Create a teacher account via the user-creation workflow
    my $t = Test::Registry::Mojo->new('Registry');

    my ($workflow) = $dao->find( Workflow => { slug => 'user-creation' } );
    ok $workflow, 'user-creation workflow found';

    # Start the workflow run
    my $next_url =
      $t->get_ok( workflow_url($workflow) )->status_is(200)
      ->element_exists('form[action="/user-creation"]')
      ->tx->res->dom->at('form[action]')->{action};

    $next_url =
      $t->post_ok( $next_url => form => {} )->status_is(302)
      ->header_like( Location => qr/info$/ )->tx->res->headers->location;

    my $run = $workflow->latest_run( $dao->db );
    ok $run, 'workflow run created for staff account';

    # Fill in user info
    $next_url =
      $t->get_ok($next_url)->status_is(200)
      ->element_exists('form[action]')
      ->element_exists('input[name="username"]')
      ->tx->res->dom->at('form[action]')->{action};

    $next_url = $t->post_ok(
        $next_url => form => {
            username => 'alex.instructor',
            password => 'securepassword123',
        }
    )->status_is(302)->header_like( Location => qr/complete$/ )
      ->tx->res->headers->location;

    # Complete the user creation
    $next_url =
      $t->get_ok($next_url)->status_is(200)
      ->element_exists('form[action]')
      ->tx->res->dom->at('form[action]')->{action};

    $t->post_ok( $next_url => form => {} )->status_is(201);

    ($run) = $dao->find( WorkflowRun => { id => $run->id } );
    ok $run->completed( $dao->db ), 'workflow run is completed';

    my ($user) = $dao->find( User => { username => 'alex.instructor' } );
    ok $user, 'teacher account created in database';
    is $user->username, 'alex.instructor', 'teacher username is correct';

    # Verify the run stored the user id
    ok $run->data->{id}, 'run data contains user id';
    is $run->data->{id}, $user->id, 'run data user id matches created user';
}

{    # Journey: Assign the teacher to a session via SessionTeacher
    my ($user) = $dao->find( User => { username => 'alex.instructor' } );
    ok $user, 'teacher found for session assignment';

    require Registry::DAO::SessionTeacher;
    my $assignment = Registry::DAO::SessionTeacher->create(
        $dao->db,
        {
            session_id => $session->id,
            teacher_id => $user->id,
        }
    );
    ok $assignment, 'teacher assigned to session';
    is $assignment->teacher( $dao->db )->username, 'alex.instructor',
      'assignment teacher username correct';
    is $assignment->session( $dao->db )->name, 'Robotics Fall 2024',
      'assignment session name correct';

    # Verify the session now lists this teacher
    my @teachers = $session->teachers( $dao->db );
    is scalar @teachers, 1, 'session has one teacher';
    is $teachers[0]->username, 'alex.instructor',
      'session teacher username is correct';
}

{    # Journey: Set role-based permissions by updating user_type to staff
    my ($user) = $dao->find( User => { username => 'alex.instructor' } );
    ok $user, 'user found for role update';

    $user->update( $dao->db, { user_type => 'staff' } );

    my ($updated_user) = $dao->find( User => { id => $user->id } );
    is $updated_user->user_type, 'staff', 'user_type set to staff';
}

{    # Journey: Create a second teacher and verify both are assigned to sessions
    my $t = Test::Registry::Mojo->new('Registry');

    my ($workflow) = $dao->find( Workflow => { slug => 'user-creation' } );

    my $next_url =
      $t->get_ok( workflow_url($workflow) )->status_is(200)
      ->tx->res->dom->at('form[action]')->{action};

    $next_url =
      $t->post_ok( $next_url => form => {} )->status_is(302)
      ->tx->res->headers->location;

    $next_url =
      $t->get_ok($next_url)->status_is(200)
      ->element_exists('form[action]')
      ->tx->res->dom->at('form[action]')->{action};

    $next_url = $t->post_ok(
        $next_url => form => {
            username => 'sarah.instructor',
            password => 'securepassword456',
        }
    )->status_is(302)->tx->res->headers->location;

    $next_url =
      $t->get_ok($next_url)->status_is(200)
      ->element_exists('form[action]')
      ->tx->res->dom->at('form[action]')->{action};

    $t->post_ok( $next_url => form => {} )->status_is(201);

    my ($sarah) = $dao->find( User => { username => 'sarah.instructor' } );
    ok $sarah, 'second teacher account created';

    # Assign the second teacher to the same session
    require Registry::DAO::SessionTeacher;
    Registry::DAO::SessionTeacher->create(
        $dao->db,
        {
            session_id => $session->id,
            teacher_id => $sarah->id,
        }
    );

    # Verify both teachers are assigned
    my @teachers = $session->teachers( $dao->db );
    is scalar @teachers, 2, 'session now has two teachers';

    my %teacher_names = map { $_->username => 1 } @teachers;
    ok $teacher_names{'alex.instructor'}, 'alex is assigned to session';
    ok $teacher_names{'sarah.instructor'}, 'sarah is assigned to session';
}
