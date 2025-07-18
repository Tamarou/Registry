use 5.40.2;
use lib          qw(lib t/lib);
use experimental qw(defer builtin);

use Test::More import => [qw( done_testing is ok )];
defer { done_testing };

use Mojo::Home;
use Registry::DAO;
use Test::Registry::DB;
use YAML::XS qw( Load );

my $test_db = Test::Registry::DB->new();
my $dao = $test_db->db;
my @files =
  Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;
for my $file (@files) {
    next if Load( $file->slurp )->{draft};
    Workflow->from_yaml( $dao, $file->slurp );
}

{
    # Add Create Event Workflow Run
    my ($workflow) = $dao->find( Workflow => { slug => 'event-creation' } );

    is $workflow->name, 'Event Creation', 'Workflow name is correct';
    my $run = $workflow->new_run( $dao->db );
    is $run->next_step( $dao->db )->slug, 'landing', 'Next step is landing';
    ok $run->process( $dao->db, $run->next_step( $dao->db ), {} ),
      'processed ok';
    is $run->next_step( $dao->db )->slug, 'info', 'Next step is info';

    my $user = $dao->create(
        User => {
            username => 'JohnnyTest',
        }
    );
    my $location = $dao->create(
        Location => {
            name => 'Event Venue',
        }
    );
    my $project = $dao->create(
        Project => {
            name => 'Event Curriculum',
        }
    );

    ok $run->process(
        $dao->db,
        $run->next_step( $dao->db ),
        {
            time        => '2021-12-31',
            teacher_id  => $user->id,
            location_id => $location->id,
            project_id  => $project->id,
        }
    );

    is $run->data()->{time},       '2021-12-31', 'run data time is updated';
    is $run->data()->{teacher_id}, $user->id,    'run data user_id is updated';

    is $run->next_step( $dao->db )->slug, 'complete', 'Next step is correct';
    $run->process( $dao->db, $run->next_step( $dao->db ), {} );

    my ($event) = $dao->find(
        Event => {
            time        => $run->data()->{time},
            location_id => $location->id
        }
    );
    die 'Event not created' unless $event;
    is $event->location( $dao->db )->name, 'Event Venue', 'Event Venue correct';
    is $event->teacher( $dao->db )->username, 'JohnnyTest',
      'Facilitator correct';
}
