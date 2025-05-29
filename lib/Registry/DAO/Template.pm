use 5.40.2;
use Object::Pad;

class Registry::DAO::Template :isa(Registry::DAO::Object) {
    field $id :param :reader;
    field $name :param :reader;
    field $slug :param :reader    = lc( $name =~ s/\s+/-/gr );
    field $content :param :reader = '';

    # TODO: Template class needs:
    # - Remove :reader metadata field
    # - Add BUILD for JSON decoding
    # - Handle { -json => $metadata } in create
    # - Add explicit metadata() accessor
    field $metadata :param :reader;
    field $notes :param :reader;
    field $created_at :param :reader;

    use constant table => 'templates';

    sub import_from_file( $class, $dao, $file ) {
        # Parse the template name from the file path
        my $name = $file->to_rel('templates') =~ s/.html.ep//r;
        
        # Generate a sensible slug from the name for special slug handling
        my $slug;
        if ($name =~ m{^(.*)/index$}) {
            # For 'workflow/index' files, create a slug like 'workflow-index'
            # This handles the case where a template is referenced as 'workflow-index' in YAML
            $slug = lc( "$1-index" =~ s/\W+/-/gr );
        } else {
            # Normal slug generation
            $slug = lc( $name =~ s/\W+/-/gr );
        }
        
        # Check if template exists by name or slug (allowing for different ways to reference it)
        my $template = $dao->find( 'Registry::DAO::Template' => { name => $name } )
                    || $dao->find( 'Registry::DAO::Template' => { slug => $slug } );
        
        # If it exists, update the content if necessary
        if ($template) {
            my $content = $file->slurp;
            if ($template->content ne $content) {
                $template = $template->update( $dao->db, { content => $content });
            }
            return $template;
        }
        
        # Create new template
        my $content = $file->slurp;
        $template = $dao->create(
            'Registry::DAO::Template' => {
                name    => $name,
                slug    => $slug,
                content => $content,
            }
        );
        
        # Try to link the template to a workflow step if it matches the pattern
        if ($template) {
            my ( $workflow_name, $step ) = $name =~ /^(?:(.*)\/)?(.*)$/;
            
            # Skip if no workflow name found
            return $template unless $workflow_name;
            
            # Handle index template special case (as landing)
            $step = 'landing' if $step eq 'index';
            
            # Try to find the workflow by slug
            my $workflow = $dao->find( 'Registry::DAO::Workflow' => { slug => $workflow_name });
            return $template unless $workflow;
            
            # Try to find the step in the workflow
            my $workflow_step = $workflow->get_step( $dao->db, { slug => $step });
            return $template unless $workflow_step;
            
            # Set the template on the step
            $workflow_step->set_template( $dao->db, $template );
        }
        
        return $template;
    }
}