use 5.40.2;
use Object::Pad;

class Registry::Controller::Tenants :isa(Registry::Controller) {
    use List::Util qw( first );

    method tenant_slug {
        return first { defined }
          $self->req->cookie('as-tenant'),
          $self->req->headers->header('X-As-Tenant');
    }

    method setup {
        my $slug = $self->tenant_slug;
        return 1 unless $slug;

        # set up the DAO helper
        my $dao = $self->app->dao;
        $self->app->helper( dao => sub { $dao->connect_schema($slug) } );
        return 1;
    }

    method index {
        $self->render( template => 'index' );
    }
}
