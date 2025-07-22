use 5.40.2;
use Object::Pad;

class Registry::Controller::Tenants :isa(Registry::Controller) {
    use List::Util qw( first );

    method tenant_slug {
        return first { defined }
          $self->req->cookie('as-tenant'),
          $self->req->headers->header('X-As-Tenant');
    }


    method index {
        $self->render( template => 'index' );
    }
}
