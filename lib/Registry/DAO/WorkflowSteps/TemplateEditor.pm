# ABOUTME: Workflow step that powers the admin template editor tool.
# ABOUTME: Supports listing, editing, saving, and reverting tenant templates.
use 5.42.0;
use Object::Pad;

class Registry::DAO::WorkflowSteps::TemplateEditor :isa(Registry::DAO::WorkflowStep) {

    method process ($db, $form_data, $run = undef) {
        $run //= do { my ($w) = $self->workflow($db); $w->latest_run($db) };

        my $action = $form_data->{action} // 'list';

        if ($action eq 'edit') {
            my $template_id = $form_data->{template_id}
                or return { stay => 1, template_data => { view => 'list', %{$self->prepare_template_data($db, $run)} } };

            my $template = Registry::DAO::Template->find($db, { id => $template_id });
            return { stay => 1, template_data => { view => 'list', %{$self->prepare_template_data($db, $run)} } }
                unless $template;

            return {
                stay          => 1,
                template_data => {
                    view     => 'edit',
                    editing_template => $template,
                    %{$self->prepare_template_data($db, $run)},
                },
            };
        }

        if ($action eq 'save') {
            my $template_id = $form_data->{template_id};
            my $content     = $form_data->{content} // '';

            if ($template_id) {
                $db->update(
                    'templates',
                    { content => $content, updated_at => \'now()' },
                    { id      => $template_id },
                );
            }

            my $template = $template_id
                ? Registry::DAO::Template->find($db, { id => $template_id })
                : undef;

            return {
                stay          => 1,
                template_data => {
                    view     => 'edit',
                    editing_template => $template,
                    flash    => 'saved',
                    %{$self->prepare_template_data($db, $run)},
                },
            };
        }

        if ($action eq 'revert') {
            my $template_id = $form_data->{template_id};

            if ($template_id) {
                my $template = Registry::DAO::Template->find($db, { id => $template_id });

                if ($template) {
                    # Fetch the canonical content from the registry (platform) schema
                    my $row = $db->query(
                        'SELECT content FROM registry.templates WHERE name = ?',
                        $template->name,
                    )->hash;

                    if ($row) {
                        $db->update(
                            'templates',
                            { content => $row->{content}, updated_at => \'now()' },
                            { id      => $template_id },
                        );
                    }

                    my $refreshed = Registry::DAO::Template->find($db, { id => $template_id });

                    return {
                        stay          => 1,
                        template_data => {
                            view     => 'edit',
                            editing_template => $refreshed,
                            flash    => 'reverted',
                            %{$self->prepare_template_data($db, $run)},
                        },
                    };
                }
            }
        }

        # Default: list view
        return {
            stay          => 1,
            template_data => {
                view => 'list',
                %{$self->prepare_template_data($db, $run)},
            },
        };
    }

    method prepare_template_data ($db, $run) {
        $db = $db->db if $db isa Registry::DAO;

        my $rows = $db->select('templates', '*', {}, { -asc => 'name' })->hashes;

        my @templates = map {
            Registry::DAO::Template->new( %$_ )
        } @$rows;

        return { templates => \@templates };
    }
}
