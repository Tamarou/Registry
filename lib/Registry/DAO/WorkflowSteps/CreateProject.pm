use 5.42.0;
use utf8;
use Object::Pad;

use Registry::DAO::Workflow;

class Registry::DAO::WorkflowSteps::CreateProject :isa(Registry::DAO::WorkflowStep) {

    method process ( $db, $, $run = undef ) {
        $run //= do { my ($w) = $self->workflow($db); $w->latest_run($db) };
        my %data       = $run->data->%{ 'name', 'metadata', 'notes' };
        my $project    = Registry::DAO::Project->create( $db, \%data );
        $run->update_data( $db, { projects => [ $project->id ] } );
        if ( $run->has_continuation ) {
            my ($continuation) = $run->continuation($db);
            my $projects = $continuation->data->{projects} // [];
            push $projects->@*, $project->id;
            $continuation->update_data( $db, { projects => $projects } );
        }
        return { project => $project->id };
    }
}