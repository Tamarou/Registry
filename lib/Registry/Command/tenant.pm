# ABOUTME: Tenant management command for Registry CLI tool  
# ABOUTME: Handles tenant list, create and other tenant operations
use 5.42.0;
use utf8;
use Object::Pad;

class Registry::Command::tenant :isa(Mojolicious::Command) {
    use Registry::Command::workflow;

    field $description :reader = 'Tenant management commands';
    field $usage :reader       = <<~"END";
        usage: $0 tenant <command> [<args>]

          commands:
            * list - list available tenant
            * show - show details about a tenant
            * inert [days] - tenants nobody has ever signed into (default 30 days)

        END

    method run( $cmd, @args ) {

        my $dao = $self->app->dao;

        if ( $cmd eq 'list' ) {
            my @tenants = $dao->find( 'Registry::DAO::Tenant', {} );
            say sprintf '%s (%s)', $_->slug, $_->name
              for sort { $a->slug cmp $b->slug } @tenants;
            return;
        }

        if ( $cmd eq 'show' ) {
            my ($slug) = @args;
            my $tenant =
              $dao->find( 'Registry::DAO::Tenant', { slug => $slug } );

            say <<~"END";

            # ${ \$tenant->name } (${ \$tenant->id })

              Created: ${ \$tenant->created_at }
              Primary Contact: ${ \($tenant->primary_user($dao->db) // '[unknown]') }
              Users: ${ \scalar $tenant->users($dao->db) }
            END

            Registry::Command::workflow->new( app => $self->app )
              ->run( 'list', $slug );

            print "\n";

            return;
        }

        # Tenants holding a subdomain that nobody has ever used (#443).
        #
        # Reports; does not reap. Freeing a slug means dropping a schema, which
        # is irreversible, and a predicate slightly wrong in an automatic job
        # would delete somebody's studio. A person reads this and decides.
        if ( $cmd eq 'inert' ) {
            my ($days) = @args;
            $days = 30 unless defined $days && $days =~ /^[0-9]+$/;

            require Registry::DAO::Tenant;
            my $inert = Registry::DAO::Tenant->inert( $dao->db, older_than_days => $days );

            unless (@$inert) {
                say "No tenants older than $days days have gone unused.";
                return;
            }

            say sprintf 'Tenants older than %d days that nobody has signed into (%d):',
                $days, scalar @$inert;
            say sprintf '  %-30s %-24s %s', $_->{slug},
                substr( $_->{created_at}, 0, 19 ), $_->{reason}
              for @$inert;
            say '';
            say 'Each of these holds its subdomain. Releasing one means dropping';
            say 'its schema, which cannot be undone -- check before you do.';
            return;
        }

        die "Unknown command `tenant $cmd`\n" . $self->usage;

    }
}

1;

