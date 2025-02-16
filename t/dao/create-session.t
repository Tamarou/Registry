use 5.40.0;
use lib          qw(lib t/lib);
use experimental qw(defer builtin);

use Test::More import => [qw( done_testing is ok )];
defer { done_testing };

use Mojo::Home;
use Registry::DAO;
use Test::Registry::DB;
use YAML::XS qw( Load );

my $dao = Registry::DAO->new( url => Test::Registry::DB->new_test_db() );
my @files =
  Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;
for my $file (@files) {
    next if Load( $file->slurp )->{draft};
    Workflow->from_yaml( $dao, $file->slurp );
}

{
    # Add Create Event Workflow Run
    my ($workflow) = $dao->find( Workflow => { slug => 'session-creation' } );

    is $workflow->name, 'Session Creation', 'Workflow name is correct';
    my $run = $workflow->new_run( $dao->db );
    is $run->next_step( $dao->db )->slug, 'landing', 'Next step is correct';
    ok $run->process( $dao->db, $run->next_step( $dao->db ), {} );
    is $run->next_step( $dao->db )->slug, 'info', 'Next step is correct';

    my $event = $dao->create(
        Event => {
            time       => '2021-12-31',
            teacher_id =>
              $dao->create( User => { username => 'JohnnyTest' } )->id,
            location_id =>
              $dao->create( Location => { name => 'Event Venue' } )->id,
            project_id =>
              $dao->create( Project => { name => 'Event Curriculum' } )->id,
        }
    );

    ok $run->process(
        $dao->db,
        $run->next_step( $dao->db ),
        { name => 'Session 1', events => [ $event->id ] }
    );

    is $run->data()->{'events'}[0], $event->id, 'run data time is updated';

    is $run->next_step( $dao->db )->slug, 'complete', 'Next step is correct';
    $run->process( $dao->db, $run->next_step( $dao->db ), {} );

    my ($session) = $dao->find( Session => { name => 'Session 1', } );
    die 'Session not created' unless $session;
    my @events = $session->events( $dao->db );
    is $events[0]->id, $event->id, 'Event Venue correct';
}
