# ABOUTME: Mojolicious plugin that makes DB-stored templates first-class in the renderer.
# ABOUTME: Overrides template resolution so DB templates get full layout, helper, and stash support.
package Mojolicious::Plugin::DBTemplates;
use Mojo::Base 'Mojolicious::Plugin', -signatures;
use Mojo::Cache;

sub register ($self, $app, $conf = {}) {
    my $renderer = $app->renderer;

    # Save original methods
    my $orig_get_data     = $renderer->can('get_data_template');
    my $orig_template_path = $renderer->can('template_path');
    my $orig_warmup       = $renderer->can('warmup');

    # Helper: look up a template in the DB
    # No caching in the plugin -- the renderer's own cache (Mojo::Cache)
    # handles repeat lookups within a request, and serverless environments
    # don't benefit from cross-request caching anyway.
    my $db_lookup = sub ($name) {
        my $dao = eval { $app->dao };
        return undef unless $dao;

        # Strip handler extensions to get the DB template name
        # e.g. "tenant-storefront/program-listing.html.ep" -> "tenant-storefront/program-listing"
        (my $db_name = $name) =~ s/\.\w+\.\w+$//;

        my $template = eval { $dao->find('Registry::DAO::Template', { name => $db_name }) };
        return $template ? $template->content : undef;
    };

    # Override template_path: if the DB has this template, return undef
    # to prevent the filesystem version from being used. This forces the
    # EPL handler to fall through to get_data_template where we serve
    # the DB content.
    Mojo::Util::monkey_patch(ref($renderer), template_path => sub ($self, $options) {
        my $name = $self->template_name($options);
        if ($name && defined $db_lookup->($name)) {
            return undef;  # DB has it -- skip filesystem
        }
        return $orig_template_path->($self, $options);
    });

    # Override get_data_template: check DATA sections first, then the DB.
    # Content returned here goes through the full rendering pipeline --
    # layouts, helpers, stash variables all work.
    Mojo::Util::monkey_patch(ref($renderer), get_data_template => sub ($self, $options) {
        my $result = $orig_get_data->($self, $options);
        return $result if defined $result;

        my $name = $self->template_name($options);
        return undef unless $name;

        return $db_lookup->($name);
    });

    # Override warmup: register DB templates in the handler index so
    # template_handler() can find them and assign the ep handler.
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
