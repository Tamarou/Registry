# ABOUTME: Landing page controller for the default workflow
# ABOUTME: Handles the root route and renders the default workflow landing page
use 5.40.2;
use Object::Pad;

class Registry::Controller::Landing :isa(Registry::Controller) {
    
    method root() {
        # Bypass Registry::Controller custom render method entirely
        # Use Mojolicious::Controller directly for proper template and layout processing
        $self->Mojolicious::Controller::render( template => 'index' );
    }
}

1;