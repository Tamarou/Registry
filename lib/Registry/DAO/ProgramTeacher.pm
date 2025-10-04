use 5.40.2;
use Object::Pad;

# ABOUTME: DAO for managing program-teacher assignments
# ABOUTME: Handles relationships between programs and teaching staff

class Registry::DAO::ProgramTeacher :isa(Registry::DAO::Object) {
    use Carp         qw( carp );
    use experimental qw(try);
    use Mojo::JSON   qw( decode_json );

    field $id :param :reader;
    field $program_id :param :reader;
    field $teacher_id :param :reader;
    field $role :param :reader = 'instructor';
    field $created_at :param :reader;

    sub table { 'program_teachers' }

    sub create ( $class, $db, $data ) {
        # Ensure table exists
        $db->query(q{
            CREATE TABLE IF NOT EXISTS program_teachers (
                id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
                program_id uuid NOT NULL REFERENCES programs(id),
                teacher_id uuid NOT NULL REFERENCES users(id),
                role text DEFAULT 'instructor',
                created_at timestamp with time zone DEFAULT now(),
                UNIQUE(program_id, teacher_id)
            )
        });

        $class->SUPER::create( $db, $data );
    }
}