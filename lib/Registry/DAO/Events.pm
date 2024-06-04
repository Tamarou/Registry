use v5.38.2;
use utf8;
use experimental qw(try);
use Object::Pad;

use Registry::DAO::Object;

class Registry::DAO::Session : isa(Registry::DAO::Object) {
    use Carp         ();
    use experimental qw(try);

    field $id : param = 0;
    field $name : param;
    field $slug : param     //= lc( $name =~ s/\s+/-/gr );
    field $metadata : param //= {};
    field $notes : param    //= '';
    field $created_at : param = time;

    use constant table => 'sessions';

    sub create ( $class, $db, $data ) {
        $data->{slug} //= lc( $data->{name} =~ s/\s+/-/gr );
        $class->SUPER::create( $db, $data );
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

class Registry::DAO::Event : isa(Registry::DAO::Object) {
    use Carp         ();
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

    use constant table => 'events';

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

