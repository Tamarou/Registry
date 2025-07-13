use 5.40.2;
use Object::Pad;

class Registry::DAO::Project :isa(Registry::DAO::Object) {
    field $id :param :reader;
    field $name :param :reader;
    field $slug :param :reader;
    field $program_type_slug :param :reader;
    field $description :param :reader = '';

    # TODO: Project class needs:
    # - Remove metadata default value
    # - Add BUILD to decode JSON strings
    # - Use { -json => $metadata } in create/update
    # - Add explicit metadata() accessor
    field $metadata :param :reader = {};
    field $notes :param :reader = '';
    field $created_at :param :reader;

    sub table { 'projects' }

    sub create ( $class, $db, $data ) {
        $data->{slug} //= lc( $data->{name} =~ s/\s+/_/gr );
        $class->SUPER::create( $db, $data );
    }

}