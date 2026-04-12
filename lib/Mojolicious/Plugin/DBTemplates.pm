# ABOUTME: Mojolicious plugin that makes DB-stored templates first-class in the renderer.
# ABOUTME: Overrides the EP handler to serve DB templates with full layout and helper support.
package Mojolicious::Plugin::DBTemplates;
use Mojo::Base 'Mojolicious::Plugin', -signatures;
use Mojo::Cache;

sub register ($self, $app, $conf = {}) {
    my $renderer = $app->renderer;

    # Save original warmup method
    my $orig_warmup = $renderer->can('warmup');

    # Helper: look up a template in the DB by name (without handler extensions).
    # Returns the template content string if found, undef otherwise.
    # Gracefully returns undef when no DAO is available (e.g. tests without
    # a full DB setup), making the plugin invisible in that case.
    my $db_lookup = sub ($name) {
        my $dao = eval { $app->dao };
        return undef unless $dao;

        # Strip handler extensions to get the DB template name
        # e.g. "tenant-storefront/program-listing.html.ep" -> "tenant-storefront/program-listing"
        (my $db_name = $name) =~ s/\.\w+\.\w+$//;

        my $template = eval { $dao->find('Registry::DAO::Template', { name => $db_name }) };
        return $template ? $template->content : undef;
    };

    # Override the EP handler to check the DB before reading from the
    # filesystem.  This avoids monkey-patching template_path (which other
    # code relies on for existence checks) while still allowing DB
    # templates to override their filesystem counterparts.
    #
    # When a DB version is found, we inject it via $options->{inline} so
    # the EPL handler compiles and renders it through Mojo::Template.
    # Because the Renderer's local $inline variable was captured from the
    # stash BEFORE the handler runs, the layout/extends loop still
    # executes afterward -- so templates with `% layout 'workflow'` work
    # correctly.
    my $orig_ep_handler = $renderer->handlers->{ep};
    $renderer->add_handler(ep => sub ($renderer, $c, $output, $options) {
        # Only intercept template-based renders (not already inline)
        my $did_inject = 0;
        unless (defined $options->{inline}) {
            my $name = $renderer->template_name($options);
            if (defined $name) {
                my $db_content = $db_lookup->($name);
                if (defined $db_content) {
                    $options->{inline} = $db_content;
                    $did_inject = 1;
                }
            }
        }

        my $result = $orig_ep_handler->($renderer, $c, $output, $options);

        # Clean up injected inline so it does not leak into the
        # Renderer's layout/extends loop, which reuses the same
        # $options hash for subsequent _render_template calls.
        delete $options->{inline} if $did_inject;

        return $result;
    });

    # Override warmup: register DB templates in the handler index so
    # template_handler() can find them and assign the ep handler.
    # Gracefully skips DB registration when no DAO is available.
    Mojo::Util::monkey_patch(ref($renderer), warmup => sub ($self) {
        $orig_warmup->($self);

        my $dao = eval { $app->dao };
        return unless $dao;

        my $templates_ref = $self->{templates} //= {};
        my @db_templates = eval {
            $dao->db->select('templates', ['name'])->hashes->each;
        };

        for my $row (@db_templates) {
            my $key = "$row->{name}.html";
            $templates_ref->{$key} //= [];
            push @{$templates_ref->{$key}}, 'ep'
                unless grep { $_ eq 'ep' } @{$templates_ref->{$key}};
        }
    });

    # Helper to invalidate the renderer's compiled template cache
    # (e.g. after template editor saves)
    $app->helper('db_templates.invalidate' => sub ($c, $name = undef) {
        # Clear the Mojo::Cache used by the EP handler for compiled templates
        $renderer->cache(Mojo::Cache->new);
        # Re-warmup to pick up any new DB templates
        $renderer->warmup;
    });
}

1;
