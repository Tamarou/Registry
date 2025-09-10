use 5.40.2;
use Object::Pad;

class Registry::DAO::SessionTeacher :isa(Registry::DAO::Object) {
    field $id :param :reader;
    field $session_id :param;
    field $teacher_id :param;
    field $created_at :param :reader;
    field $updated_at :param :reader;

    sub table { 'session_teachers' }

    # Get the session this teacher assignment belongs to
    method session($db) {
        Registry::DAO::Session->find( $db, { id => $session_id } );
    }

    # Get the teacher assigned to the session
    method teacher($db) {
        Registry::DAO::User->find( $db, { id => $teacher_id } );
    }
}