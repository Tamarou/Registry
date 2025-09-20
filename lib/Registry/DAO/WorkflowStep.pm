use 5.40.2;
use Object::Pad;

class Registry::DAO::WorkflowStep :isa(Registry::DAO::Object) {
    use Carp qw(confess);

    field $id :param :reader;
    field $slug :param :reader;
    field $workflow_id :param :reader;
    field $template_id :param :reader           = undef;
    field $outcome_definition_id :param :reader = undef;
    field $description :param :reader;

    field $depends_on :param = undef;

    # TODO: WorkflowStep class needs:
    # - Remove = {} default
    # - Add BUILD for JSON decoding
    # - Handle { -json => $metadata } in create/update
    # - Add explicit metadata() accessor
    field $metadata :param = {};
    field $class :param :reader;

    sub table { 'workflow_steps' }
    
    method outcome_definition($db) {
        return unless $outcome_definition_id;
        Registry::DAO::OutcomeDefinition->find($db, { id => $outcome_definition_id });
    }
    
    method get_schema_definition($db) {
        my $definition = $self->outcome_definition($db);
        return unless $definition;
        return $definition->schema;
    }
    
    method validate($db, $data) {
        my $definition = $self->outcome_definition($db);
        return { valid => 1 } unless $definition; # Skip validation if no definition
        
        # Get validation rules from outcome definition
        my $schema = $definition->schema;
        my @errors;
        
        # Basic field validation using JSON Schema
        for my $field ($schema->{fields}->@*) {
            my $field_id = $field->{id};
            # Check required fields
            if ($field->{required} && !defined $data->{$field_id}) {
                push @errors, {
                    field => $field_id,
                    message => "Field is required"
                };
                next;
            }
            
            # Additional validation for specific field types could be added here
        }
        
        return {
            valid => @errors ? 0 : 1,
            errors => \@errors
        };
    }
    
    # we store the subclass name in the database
    # so we need inflate the correct one
    sub find ( $class, $db, $filter, $order = { -desc => 'created_at' } ) {
        try {
            $db = $db->db if $db isa Registry::DAO;
            my $data =
              $db->select( $class->table, '*', $filter, $order )->expand->hash;
            return unless $data;

            # Load the workflow step class module before calling new() on it
            my $step_class = $data->{class};
            eval "require $step_class" or confess "Failed to load workflow step class $step_class: $@";

            return $step_class->new( $data->%* );
        }
        catch ($e) {
            confess $e;
        }
    }

    sub create ( $class, $db, $data ) {
        $data->{class} //= $class;
        $class->SUPER::create( $db, $data );
    }

    method next_step ($db) {
        Registry::DAO::WorkflowStep->find( $db, { depends_on => $id } );
    }

    method template ($db) {
        die "no template set for step $slug ($id)" unless $template_id;
        return Registry::DAO::Template->find( $db, { id => $template_id } );
    }
    
    # Default template data preparation - can be overridden by specific step classes
    method prepare_template_data ($db, $run) {
        # Most steps just need the raw run data
        return $run->data || {};
    }

    method as_hash ($db) {
        # Create a base hash with only the fields that exist
        my $json = {};
        
        # Add basic fields if they exist
        $json->{slug} = $slug if $slug;
        $json->{description} = $description if $description;
        $json->{class} = $class if $class;
        
        # Get template information if it exists
        if ($template_id) {
            my $template_obj = $self->template($db);
            $json->{template} = $template_obj->slug if $template_obj;
        }
        
        # Get outcome definition information if it exists
        if ($outcome_definition_id) {
            my $outcome_obj = Registry::DAO::OutcomeDefinition->find($db, { id => $outcome_definition_id });
            if ($outcome_obj) {
                $json->{'outcome-definition'} = $outcome_obj->name;
            }
        }
        
        return $json;
    }

    method set_template ( $db, $template_id ) {
        $template_id = $template_id->id
          if $template_id isa Registry::DAO::Template;
        $db = $db->db if $db isa Registry::DAO;
        $db->update(
            $self->table,
            { template_id => $template_id },
            { id          => $id }
        );
    }

    method workflow ($db) {
        Registry::DAO::Workflow->find( $db, { id => $workflow_id } );
    }

    method process ( $db, $data ) { 
        # Always validate input
        my $validation = $self->validate($db, $data);
        if (!$validation->{valid}) {
            return { _validation_errors => $validation->{errors} };
        }
        
        # Default implementation - simple passthrough
        return $data;
    }
}