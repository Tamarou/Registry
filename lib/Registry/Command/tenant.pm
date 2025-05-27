use v5.34.0;
use utf8;
use Object::Pad;

use Registry::Command::workflow;

class Registry::Command::tenant :isa(Mojolicious::Command) {

    field $description :reader = 'Tenant management commands';
    field $usage :reader       = <<~"END";
        usage: $0 tenant <command> [<args>]

          commands:
            * list - list available tenant
            * show - show details about a tenant

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

        die "Unknown command `tenant $cmd`\n" . $self->usage;

    }
}

