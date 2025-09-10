use 5.40.2;
use Object::Pad;

class Registry::Controller::Tenants :isa(Registry::Controller) {

    method tenant_slug {
        # Delegate to app helper which handles proper precedence
        return $self->tenant;
    }


    method index {
        $self->render( template => 'index' );
    }
}
