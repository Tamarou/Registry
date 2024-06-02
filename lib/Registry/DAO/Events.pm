use v5.38.2;
use utf8;
use experimental qw(try);
use Object::Pad;

class Registry::DAO::Session {
    use Carp         qw( carp croak );
    use experimental qw(try);

    field $id : param = 0;
    field $name : param;
    field $slug : param     //= lc( $name =~ s/\s+/-/gr );
    field $metadata : param //= {};
    field $notes : param    //= '';
    field $created_at : param = time;

    sub find ( $, $db, $filter ) {
        my $data = $db->select( 'sessions', '*', $filter )->hash;
        return $data ? __PACKAGE__->new( $data->%* ) : ();
    }

    sub create ( $class, $db, $data ) {
        try {
            $data->{slug} //= $class->new( $data->%* )->slug;
        }
        catch ($e) {
            croak $e;
        };

        $data =
          $db->insert( 'sessions', $data, { returning => '*' } )->expand->hash;

        return $class->new( $data->%* );
    }

    method id   { $id }
    method name { $name }
    method slug { $slug }

    method events ($db) {

        # TODO: this should be a join
        $db->select( 'session_events', '*', { session_id => $id } )
          ->hashes->map(
            sub { Registry::DAO::Event->find( $db, { id => $_->{event_id} } ) }
        )->to_array->@*;
    }

    method add_events ( $db, @events ) {
        my $data = [ map { { session_id => $id, event_id => $_ } } @events ];
        $db->insert( 'session_events', $data->@* );
    }

}

class Registry::DAO::Event {
    use Carp         qw( carp croak );
    use experimental qw(try);

    field $id : param;
    field $time : param;
    field $duration : param;
    field $location_id : param;
    field $project_id : param;
    field $teacher_id : param;
    field $metadata : param;
    field $notes : param;
    field $created_at : param;

    sub find ( $, $db, $filter ) {
        my $data = $db->select( 'events', '*', $filter )->hash;
        return $data ? __PACKAGE__->new( $data->%* ) : ();
    }

    sub create ( $, $db, $data //= carp "must provide data" ) {

        __PACKAGE__->new(
            $db->insert( 'events', $data, { returning => '*' } )
              ->expand->hash->%* );
    }

    sub find_or_create ( $, $db, $data ) {
        __PACKAGE__->new(
            $db->insert(
                'events', $data,
                {
                    on_conflict => [
                        [ 'product_id', 'lesson_id', 'location_id', 'time' ] =>
                          {
                            product_id  => \'EXCLUDED.product_id',
                            location_id => \'EXCLUDED.location_id',
                            time        => \'EXCLUDED.time',
                          }
                    ],
                    returning => '*'
                }
            )->expand->hash->%*
        );
    }

    method id { $id }

    method location ($db) {
        Registry::DAO::Location->find( $db, { id => $location_id } );
    }

    method teacher ($db) {
        Registry::DAO::User->find( $db, { id => $teacher_id } );
    }

    method project ($db) {
        Registry::DAO::Project->find( $db, { id => $project_id } );
    }
}    # classes / days

