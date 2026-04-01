# ABOUTME: Morgan (program administrator) user journey test for program management.
# ABOUTME: Creates programs via the project-creation workflow and manages them via DAO calls.
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

{    # Journey: Create a new educational program via the project-creation workflow
    my $t = Test::Registry::Mojo->new('Registry');

    my ($workflow) =
      $dao->find( Workflow => { slug => 'project-creation' } );
    ok $workflow, 'project-creation workflow found';

    # Start the workflow run by POSTing to the workflow start URL
    my $next_url =
      $t->post_ok( workflow_url($workflow) => form => {} )->status_is(302)
      ->header_like( Location => qr/info$/ )->tx->res->headers->location;

    my $run = $workflow->latest_run( $dao->db );
    ok $run, 'workflow run created for program creation';

    # Fill in project info - name and notes represent the program
    $next_url =
      $t->get_ok($next_url)->status_is(200)
      ->element_exists('form[action]')
      ->tx->res->dom->at('form[action]')->{action};

    $next_url = $t->post_ok(
        $next_url => form => {
            name  => 'STEM Explorers',
            notes => 'Hands-on science and technology activities',
        }
    )->status_is(302)->header_like( Location => qr/complete$/ )
      ->tx->res->headers->location;

    # Confirm creation on the complete step
    $next_url =
      $t->get_ok($next_url)->status_is(200)
      ->element_exists('form[action]')
      ->tx->res->dom->at('form[action]')->{action};

    $t->post_ok( $next_url => form => {} )->status_is(201);

    # Verify the program (project) was created in the database
    my ($project) = $dao->find( Project => { name => 'STEM Explorers' } );
    ok $project, 'program created in database';
    is $project->name,  'STEM Explorers',                     'program name is correct';
    is $project->notes, 'Hands-on science and technology activities',
      'program notes are correct';

    # Verify the run is complete
    ($run) = $dao->find( WorkflowRun => { id => $run->id } );
    ok $run->completed( $dao->db ), 'workflow run completed';
}

{    # Journey: Update an existing program's notes via DAO
    my ($project) = $dao->find( Project => { name => 'STEM Explorers' } );
    ok $project, 'program found for update';

    $project->update(
        $dao->db,
        { notes => 'Updated: focus on robotics added for fall semester' }
    );

    my ($updated) = $dao->find( Project => { id => $project->id } );
    is $updated->notes, 'Updated: focus on robotics added for fall semester',
      'program notes updated correctly';
}

{    # Journey: Assign a teacher to a session linked to the program
    my ($project) = $dao->find( Project => { name => 'STEM Explorers' } );

    my $teacher = $dao->create(
        User => {
            username  => 'alex.teacher',
            user_type => 'staff',
        }
    );
    ok $teacher, 'teacher account created';
    is $teacher->user_type, 'staff', 'teacher has staff role';

    my $session = $dao->create(
        Session => {
            name       => 'STEM Explorers - Fall',
            project_id => $project->id,
        }
    );
    ok $session, 'session created for program';

    require Registry::DAO::SessionTeacher;
    my $assignment = Registry::DAO::SessionTeacher->create(
        $dao->db,
        {
            session_id => $session->id,
            teacher_id => $teacher->id,
        }
    );
    ok $assignment, 'teacher assigned to session';
    is $assignment->teacher( $dao->db )->username, 'alex.teacher',
      'assigned teacher username is correct';
    is $assignment->session( $dao->db )->name, 'STEM Explorers - Fall',
      'assigned session name is correct';
}

{    # Journey: Set program schedule by updating session metadata
    my ($session) =
      $dao->find( Session => { name => 'STEM Explorers - Fall' } );
    ok $session, 'session found for schedule update';

    $session->update(
        $dao->db,
        {
            metadata => {
                -json => {
                    schedule_pattern => {
                        type                     => 'weekly',
                        duration_weeks           => 12,
                        sessions_per_week        => 2,
                        session_duration_minutes => 120,
                        default_start_time       => '15:00',
                    }
                }
            }
        }
    );

    my ($updated_session) = $dao->find( Session => { id => $session->id } );
    my $pattern = $updated_session->metadata->{schedule_pattern};
    ok $pattern, 'schedule pattern stored in session metadata';
    is $pattern->{duration_weeks},           12,  'schedule duration is 12 weeks';
    is $pattern->{sessions_per_week},        2,   'schedule has 2 sessions per week';
    is $pattern->{session_duration_minutes}, 120, 'session duration is 120 minutes';
}
