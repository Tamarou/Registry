use 5.40.0;
use Object::Pad;

class Registry::Controller::Customers : isa(Mojolicious::Controller) {
    use List::Util qw( first );

    method customer_slug {
        return first { defined }
          $self->req->cookie('as-customer'),
          $self->req->headers->header('X-As-Customer');
    }

    method setup {
        my $slug = $self->customer_slug;
        return 1 unless $slug;

        # set up the DAO helper
        my $dao = $self->app->dao;
        $self->app->helper(
            dao => sub {
                state $db = $dao->connect_schema($slug);
            }
        );
        return 1;
    }
}
