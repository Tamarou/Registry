# ABOUTME: DAO class for individual workflow steps with metadata, templates, and outcome definitions.
# ABOUTME: Subclassed by step-specific classes in WorkflowSteps/ for custom process/prepare logic.
use 5.42.0;
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

    # Mojo::Pg's ->expand (in Object::find/create) decodes jsonb to a
    # hashref automatically.  ADJUST coerces NULL/undef to {} so callers
    # always get a hashref.
    field $metadata :param :reader = undef;
    field $class :param :reader;

    ADJUST { $metadata //= {} }

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
    
    # Default template data preparation - can be overridden by specific step classes.
    # $params is an optional hashref of query parameters from the request,
    # allowing step classes to load section-specific data for HTMX partial updates.
    method prepare_template_data ($db, $run, $params = {}) {
        # Most steps just need the raw run data
        return $run->data || {};
    }

    # Re-nest Rails-style bracketed form field names into a hashref. Mojo's
    # param->to_hash delivers fields like "a[b][c]" as flat string keys; steps
    # with per-row form data (e.g. location_configs[<id>][capacity]) need them
    # nested. Non-bracketed keys pass through unchanged.
    #
    # When all keys in a nested sub-hash are non-negative integers the sub-hash
    # is converted to an arrayref sorted by index (matching PHP/Rails convention
    # for fields like team_members[0][name], team_members[1][name]).
    method expand_form_params ($form_data) {
        my %out;
        for my $key ( sort keys %$form_data ) {
            my $val = $form_data->{$key};
            if ( my ($head, $brackets) = $key =~ /\A([^\[]+)((?:\[[^\]]*\])+)\z/ ) {
                my @path = ( $head, $brackets =~ /\[([^\]]*)\]/g );
                my $ref = \%out;
                while ( @path > 1 ) {
                    my $p = shift @path;
                    $ref->{$p} = {} unless ref $ref->{$p} eq 'HASH';
                    $ref = $ref->{$p};
                }
                $ref->{ $path[0] } = $val;
            }
            else {
                $out{$key} = $val;
            }
        }
        # Post-process: convert any hash whose keys are all non-negative integers
        # into a sorted arrayref so callers receive a proper list structure.
        $self->_arrayify_numeric_hashes( \%out );
        return \%out;
    }

    # Recursively convert hashrefs with all-numeric keys to sorted arrayrefs.
    method _arrayify_numeric_hashes ($node) {
        return unless ref $node eq 'HASH';
        for my $k ( keys %$node ) {
            if ( ref $node->{$k} eq 'HASH' ) {
                $self->_arrayify_numeric_hashes( $node->{$k} );
                my @keys = keys %{ $node->{$k} };
                if ( @keys && !grep { /\D/ } @keys ) {
                    $node->{$k} = [ map { $node->{$k}{$_} } sort { $a <=> $b } @keys ];
                }
            }
        }
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

    method process ( $db, $data, $run = undef ) {
        # Expand Rails-style bracketed param names (e.g. team_members[0][name])
        # into nested hashrefs so run data contains proper structures.
        $data = $self->expand_form_params($data);

        # Always validate input
        my $validation = $self->validate($db, $data);
        if (!$validation->{valid}) {
            return { _validation_errors => $validation->{errors} };
        }

        # Default implementation - simple passthrough
        return $data;
    }
}