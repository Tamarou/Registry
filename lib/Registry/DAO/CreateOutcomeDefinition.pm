use 5.40.0;
use Object::Pad;

class Registry::DAO::CreateOutcomeDefinition :isa(Registry::DAO::WorkflowStep) {
    use Mojo::JSON qw(encode_json);
    use Carp qw(carp);
    
    method process ($db, $data) {
        my ($workflow) = $self->workflow($db);
        my $run = $workflow->latest_run($db);
        
        # Merge data from previous steps
        my $outcome_data = {
            name => $run->data->{name},
            description => $run->data->{description},
            schema => {
                name => $run->data->{name},
                description => $run->data->{description},
                fields => $run->data->{fields}
            }
        };
        
        # Create the outcome definition
        my $outcome = Registry::DAO::OutcomeDefinition->create($db, $outcome_data);
        
        # Update run data
        $run->update_data($db, { outcome_definition_id => $outcome->id });
        
        # If this workflow is part of a continuation, update the parent
        if ($run->has_continuation) {
            my ($continuation) = $run->continuation($db);
            my $outcomes = $continuation->data->{outcomes} // [];
            push @$outcomes, $outcome->id;
            $continuation->update_data($db, { outcomes => $outcomes });
        }
        
        return { outcome_definition_id => $outcome->id };
    }
}