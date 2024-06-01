use v5.38.2;
use utf8;
use experimental qw(class builtin);

class Registry::DAO::Session {
    field $id : param;
    field $name : param;
    field $slug : param;
    field $metadata : param;
    field $notes : param;
    field $created_at : param;

    sub find ( $, $db, $filter ) {
        my $data = $db->select( 'sessions', '*', $filter )->hash;
        return $data ? __PACKAGE__->new( $data->%* ) : ();
    }

    sub create ( $, $db, $data ) {
        $data->{slug} //= lc( $data->{name} =~ s/\s+/-/gr );
        __PACKAGE__->new(
            $db->insert( 'sessions', $data, { returning => '*' } )
              ->expand->hash->%* );
    }

    method id { $id }

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

    sub create ( $, $db, $data ) {
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
}    # classes / days

