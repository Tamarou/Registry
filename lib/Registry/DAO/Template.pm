# ABOUTME: DAO class for DB-stored templates with content, metadata, and file import.
# ABOUTME: Used by DBTemplates plugin to serve tenant-customizable templates from the database.
use 5.42.0;
use Object::Pad;

class Registry::DAO::Template :isa(Registry::DAO::Object) {
    use Digest::SHA qw( sha256_hex );

    field $id :param :reader;
    field $name :param :reader;
    field $slug :param :reader    = lc( $name =~ s/\s+/-/gr );
    field $content :param :reader = '';

    # Mojo::Pg's ->expand (in Object::find/create) decodes jsonb to a
    # hashref automatically.  ADJUST coerces NULL/undef to {} so callers
    # always get a hashref.
    field $metadata :param :reader = undef;
    field $notes :param :reader;
    field $created_at :param :reader;
    field $updated_at :param :reader = undef;

    ADJUST { $metadata //= {} }

    sub table { 'templates' }

    # Hash of a template's bytes. The file arrives as bytes and the database
    # returns characters, so normalise before hashing or a template containing
    # anything non-ASCII would look modified the moment it round-tripped.
    my sub _sha ($text) {
        my $bytes = $text // '';
        utf8::encode($bytes) if utf8::is_utf8($bytes);
        return sha256_hex($bytes);
    }

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
        
        # Ensure UTF-8 encoding when reading file
        my $content = $file->slurp;  # Mojo::File slurp already handles UTF-8 correctly

        # Whether import may write is a question about this row, not about which
        # schema it is in. Registry is the root tenant rather than a different
        # kind of thing, so the same rule governs every schema: a row still
        # holding exactly what the last import left is unmodified and the file
        # may carry it forward; a row that has drifted from its stamp was
        # customised by whoever owns it, and import leaves it alone.
        #
        # The previous form returned early on any existing row, which protected
        # customisation by giving platform templates no deploy path at all --
        # the file changed, the deployed row did not, and nothing reconciled
        # them (#352).
        #
        # An unstamped row predates this mechanism. Treating it as unmodified is
        # what lets those rows reconcile the first time; from then on every row
        # carries a stamp and an edit is protected.
        if ($template) {
            my $metadata = $template->metadata // {};
            my $stamp    = $metadata->{imported_sha256};

            return $template
              if defined $stamp && $stamp ne _sha( $template->content );
            return $template if $content eq $template->content;

            $dao->db->update(
                'templates',
                {
                    content  => $content,
                    metadata =>
                      { -json => { %$metadata, imported_sha256 => _sha($content) } },
                    updated_at => \'now()',
                },
                { id => $template->id },
            );
            return $dao->find( 'Registry::DAO::Template' => { id => $template->id } );
        }

        $template = $dao->create(
            'Registry::DAO::Template' => {
                name     => $name,
                slug     => $slug,
                content  => $content,
                metadata => { -json => { imported_sha256 => _sha($content) } },
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