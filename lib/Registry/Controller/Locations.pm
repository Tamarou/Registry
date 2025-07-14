use 5.40.2;
use Object::Pad;

class Registry::Controller::Locations :isa(Mojolicious::Controller) {
    
    method show ($slug = $self->param('slug')) {
        # Get tenant from header and pass it explicitly to DAO helper
        my $tenant = $self->req->headers->header('X-As-Tenant');
        my $dao = $self->app->dao($tenant);
        
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
