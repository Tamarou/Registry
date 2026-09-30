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
            * inert [days|never] - tenants nobody has ever signed into
                 (default: the inert_tenant_days platform setting, or 90)

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
            require Registry::DAO::Tenant;

            my ($days) = @args;
            my %opt;
            if ( defined $days && length $days ) {
                if ( $days =~ /^[1-9][0-9]*$/ ) {
                    $opt{older_than_days} = 0 + $days;
                }
                else {
                    # Including 'never'. Refused rather than silently treated as
                    # the default: somebody typing it means to ask a question,
                    # and answering a different one is worse than saying no.
                    say "'$days' is not a number of days.";
                    say 'To switch reclaiming off: platform set inert_tenant_days 0';
                    return;
                }
            }

            my $result = Registry::DAO::Tenant->inert( $dao->db, %opt );

            # Off is said, not shown as an empty list. The two read identically
            # and only one of them means "nothing to do".
            unless ( $result->{enabled} ) {
                say 'Reclaiming is switched off (inert_tenant_days = 0),';
                say 'so no tenant is considered inert. Pass a number of days to look anyway.';
                return;
            }

            my $window = $result->{window_days};
            my $tenants = $result->{tenants};

            unless (@$tenants) {
                say "No tenants older than $window days have gone unused.";
                return;
            }

            say sprintf 'Tenants older than %d days that nobody has signed into (%d):',
                $window, scalar @$tenants;
            say sprintf '  %-30s %-24s %s', $_->{slug},
                substr( $_->{created_at}, 0, 19 ), $_->{reason}
              for @$tenants;
            say '';
            say 'Each of these holds its subdomain. Releasing one means dropping';
            say 'its schema, which cannot be undone -- check before you do.';
            return;
        }

        die "Unknown command `tenant $cmd`\n" . $self->usage;

    }
}

1;

