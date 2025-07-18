# ABOUTME: Base object class for all Registry DAO entities with common CRUD operations
# ABOUTME: Provides find, create, update methods and database interaction patterns
use 5.40.2;
use utf8;
use Object::Pad;

package Registry::DAO::Object;

class Registry::DAO::Object {
    use Carp         qw( carp confess );
    use experimental qw(builtin try);
    use builtin      qw(blessed);

    sub table($) { ... }

    sub find ( $class, $db, $filter = {}, $order = { -desc => 'created_at' } ) {
        $db = $db->db if $db isa Registry::DAO;
        my $c = $db->select( $class->table, '*', $filter, $order )
          ->expand->hashes->map( sub { $class->new( $_->%* ) } );
        return wantarray ? $c->to_array->@* : $c->first;
    }

    sub create ( $class, $db, $data ) {
        $db = $db->db if $db isa Registry::DAO;
        my %data =
          $db->insert( $class->table, $data, { returning => '*' } )
          ->expand->hash->%*;
        return $class->new(%data);
    }

    sub find_or_create ( $class, $db, $filter, $data = $filter ) {
        $db = $db->db if $db isa Registry::DAO;
        if ( my @objects = $class->find( $db, $filter ) ) {
            return unless defined wantarray;
            return wantarray ? @objects : $objects[0];
        }
        return $class->create( $db, $data );
    }

    method update ( $db, $data, $filter = { id => $self->id } ) {
        $db = $db->db if $db isa Registry::DAO;
        try {
            my $new =
              $db->update( $self->table, $data, $filter, { returning => '*' } )
              ->expand->hash;
            return blessed($self)->new( $new->%* );
        }
        catch ($e) {
            carp "Error updating $self: $e";
        };
    }
}

1;
