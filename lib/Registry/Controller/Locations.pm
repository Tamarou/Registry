use 5.40.2;
use Object::Pad;

class Registry::Controller::Locations :isa(Mojolicious::Controller) {
    
    method show ($slug = $self->param('slug')) {
        # Get tenant using app helper which handles precedence properly
        my $tenant = $self->tenant;
        my $dao = $self->dao($tenant);
        
        my ($location) = $dao->find(Location => {slug => $slug});
        
        unless ($location) {
            return $self->render(text => 'Location not found', status => 404);
        }
        
        $self->render(
            'locations/show',
            location => $location
        );
    }
}

1;
