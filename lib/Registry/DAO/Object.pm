# ABOUTME: Base object class for all Registry DAO entities with common CRUD operations
# ABOUTME: Provides find, create, update methods and database interaction patterns
use 5.42.0;
use utf8;
use Object::Pad;

class Registry::DAO::Object {
    use Carp         qw( carp confess );



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

    # Fails loudly, deliberately.
    #
    # This used to wrap the UPDATE in try/catch and carp, returning undef, so a
    # caller could not tell a failed persist from a successful one. Money-path
    # sites rely on it -- Payment::create_payment_intent persists Stripe intent
    # ids and statuses through here -- and a database failure there left the row
    # disagreeing with the live Stripe object, with a line on stderr as the only
    # trace. Payment::save was written to bypass update() for exactly this
    # reason; the base now behaves the way that workaround wanted.
    method update ( $db, $data, $filter = { id => $self->id } ) {
        $db = $db->db if $db isa Registry::DAO;

        my $new = $db->update( $self->table, $data, $filter, { returning => '*' } )
          ->expand->hash;

        # Matching no row was equally silent: ->hash returned undef and
        # dereferencing it threw inside the same try that swallowed real errors,
        # so "the row is gone" and "the database refused" looked identical.
        confess sprintf 'update on %s matched no row', $self->table
          unless $new;

        return blessed($self)->new( $new->%* );
    }
}

1;
