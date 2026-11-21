# ABOUTME: Morgan (program administrator) user journey test for curriculum development.
# ABOUTME: Tests the CurriculumDetails workflow step class directly with program-creation-enhanced.
use 5.42.0;
use lib          qw(lib t/lib);
use experimental qw(defer);

use Test::More import => [qw( done_testing is ok is_deeply like )];
defer { done_testing };

use Mojo::Home;
use Registry::DAO                                    qw(Workflow);
use Registry::DAO::WorkflowSteps::CurriculumDetails  ();
use Test::Registry::DB                               ();
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

my ($workflow) =
  $dao->find( Workflow => { slug => 'program-creation-enhanced' } );
ok $workflow, 'program-creation-enhanced workflow found';

# Look up the seeded afterschool program type
require Registry::DAO::ProgramType;
my $program_type =
  Registry::DAO::ProgramType->find_by_slug( $dao->db, 'afterschool' );
ok $program_type, 'afterschool program type found';

# Helper: advance a run past program-type-selection by directly writing run data.
# ProgramTypeSelection->process() calls ProgramType->new(id=>..)->load() which
# requires all Object::Pad constructor params and is not testable in isolation.
# The direct DB update replicates exactly what that step would persist.
# Returns the refreshed run after advancing past program-type-selection.
my $advance_past_type_selection = sub ($run) {
    my $type_step = $workflow->first_step( $dao->db );
    $dao->db->update(
        'workflow_runs',
        {
            data => {
                -json => {
                    program_type_id     => $program_type->id,
                    program_type_name   => $program_type->name,
                    program_type_config => $program_type->config,
                }
            },
            latest_step_id => $type_step->id,
        },
        { id => $run->id }
    );
    # Re-fetch the run so its in-memory latest_step_id reflects the update
    my ($refreshed_run) = $dao->find( WorkflowRun => { id => $run->id } );
    return ( $refreshed_run, $type_step );
};

{    # Journey: Create new curriculum materials via the curriculum-details step
    my $run = $workflow->new_run( $dao->db );
    ok $run, 'workflow run created';

    my ($refreshed_run, $type_step) = $advance_past_type_selection->($run);
    ok $type_step, 'program-type-selection step advanced';

    my $curriculum_step = $refreshed_run->next_step( $dao->db );
    ok $curriculum_step, 'curriculum-details step is next';
    is $curriculum_step->slug, 'curriculum-details',
      'next step slug is curriculum-details';

    my $result = $refreshed_run->process(
        $dao->db,
        $curriculum_step,
        {
            name                => 'STEM Explorers Curriculum',
            description         => 'Hands-on STEM activities for grades 1-6',
            learning_objectives =>
              'Students will learn basic programming; Students will apply engineering principles',
            materials_needed => 'Computers, building blocks, notebooks',
            skills_developed => 'Problem solving, teamwork, creativity',
        }
    );

    ok $result, 'curriculum-details step processed successfully';

    my ($updated_run) = $dao->find( WorkflowRun => { id => $refreshed_run->id } );
    my $curriculum = $updated_run->data->{curriculum};
    ok $curriculum, 'curriculum data stored in workflow run';
    is $curriculum->{name}, 'STEM Explorers Curriculum',
      'curriculum name stored correctly';
    is $curriculum->{description}, 'Hands-on STEM activities for grades 1-6',
      'curriculum description stored correctly';
    ok $curriculum->{learning_objectives}, 'learning objectives stored';
    ok $curriculum->{materials_needed},    'materials needed stored';
    ok $curriculum->{skills_developed},    'skills developed stored';
}

{    # Journey: Organize materials into structured lessons via curriculum details
    my $run = $workflow->new_run( $dao->db );
    my ($refreshed_run2) = $advance_past_type_selection->($run);

    my $curriculum_step = $refreshed_run2->next_step( $dao->db );
    $refreshed_run2->process(
        $dao->db,
        $curriculum_step,
        {
            name        => 'Creative Arts Curriculum',
            description => 'Structured arts program with weekly themes',
            learning_objectives =>
              'Week 1: Introduction to drawing; Week 2: Watercolor painting; Week 3: Sculpture',
            materials_needed => 'Drawing paper, watercolor paints, clay',
            skills_developed => 'Fine motor skills, artistic expression',
        }
    );

    my ($updated_run) = $dao->find( WorkflowRun => { id => $refreshed_run2->id } );
    my $curriculum = $updated_run->data->{curriculum};
    ok $curriculum, 'structured curriculum data stored';
    like $curriculum->{learning_objectives}, qr/Week 1/,
      'lesson week 1 in objectives';
    like $curriculum->{learning_objectives}, qr/Week 2/,
      'lesson week 2 in objectives';
    like $curriculum->{learning_objectives}, qr/Week 3/,
      'lesson week 3 in objectives';
}

{    # Journey: Link materials to program type standards via program_type_config in run data
    my $run = $workflow->new_run( $dao->db );
    my ($refreshed_run3) = $advance_past_type_selection->($run);

    my ($updated_run) = $dao->find( WorkflowRun => { id => $refreshed_run3->id } );
    ok $updated_run->data->{program_type_id}, 'program type linked to run';
    is $updated_run->data->{program_type_id}, $program_type->id,
      'run is linked to the correct program type';
    ok $updated_run->data->{program_type_name},
      'program type name stored for display';
}

{    # Journey: Share curriculum materials with staff - verify skills and materials accessible
    my $run = $workflow->new_run( $dao->db );
    my ($refreshed_run4) = $advance_past_type_selection->($run);

    my $curriculum_step = $refreshed_run4->next_step( $dao->db );
    $refreshed_run4->process(
        $dao->db,
        $curriculum_step,
        {
            name                => 'Shared STEM Materials',
            description         => 'Materials to be shared with teaching staff',
            learning_objectives => 'Staff-facing learning objectives',
            skills_developed    => 'Python, electronics, robotics',
            materials_needed    => 'Raspberry Pi kits, sensors, breadboards',
        }
    );

    my ($updated_run) = $dao->find( WorkflowRun => { id => $refreshed_run4->id } );
    my $curriculum = $updated_run->data->{curriculum};
    ok $curriculum, 'curriculum data accessible for staff sharing';
    is $curriculum->{skills_developed}, 'Python, electronics, robotics',
      'skills developed accessible to staff';
    is $curriculum->{materials_needed}, 'Raspberry Pi kits, sensors, breadboards',
      'materials list accessible to staff';
}
