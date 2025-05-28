use 5.40.0;
use Object::Pad;

class Registry::Controller::Marketing :isa(Registry::Controller) {

    method index {
        # Set SEO metadata
        $self->stash(
            title => 'Registry - After-School Program Management Made Simple',
            description => 'Streamline your after-school programs with Registry. Manage registrations, track attendance, handle payments, and communicate with families. 30-day free trial.',
            keywords => 'after-school programs, registration software, program management, student tracking, attendance, payments'
        );
        
        $self->render( template => 'marketing/index' );
    }
}