use 5.40.0;
use lib          qw(lib t/lib);
use experimental qw(defer builtin);

use Test::More import => [qw( done_testing is ok like )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;

# Create a test database with the summer camp schema
my $dao = Registry::DAO->new( url => Test::Registry::DB->new_test_db() );
my $db  = $dao->db;

# 1. Test the locations table enhancements
{
    my $location_columns = $db->query(
        q{
        SELECT column_name, data_type
        FROM information_schema.columns
        WHERE table_name = 'locations'
    }
    )->hashes;

    # Check for summer camp fields
    ok
      scalar( grep { $_->{column_name} eq 'address_street' }
          $location_columns->@* ),
      'locations table has address_street column';
    ok
      scalar( grep { $_->{column_name} eq 'address_city' }
          $location_columns->@* ),
      'locations table has address_city column';
    ok
      scalar( grep { $_->{column_name} eq 'address_state' }
          $location_columns->@* ),
      'locations table has address_state column';
    ok
      scalar( grep { $_->{column_name} eq 'address_zip' }
          $location_columns->@* ),
      'locations table has address_zip column';
    ok scalar( grep { $_->{column_name} eq 'capacity' } $location_columns->@* ),
      'locations table has capacity column';
    ok
      scalar( grep { $_->{column_name} eq 'contact_info' }
          $location_columns->@* ),
      'locations table has contact_info column';
    ok
      scalar( grep { $_->{column_name} eq 'facilities' }
          $location_columns->@* ),
      'locations table has facilities column';
    ok scalar( grep { $_->{column_name} eq 'latitude' } $location_columns->@* ),
      'locations table has latitude column';
    ok
      scalar( grep { $_->{column_name} eq 'longitude' } $location_columns->@* ),
      'locations table has longitude column';
}

# 2. Test the events table enhancements
{
    my $event_columns = $db->query(
        q{
        SELECT column_name, data_type
        FROM information_schema.columns
        WHERE table_name = 'events'
    }
    )->hashes;

    # Check for summer camp fields
    ok scalar( grep { $_->{column_name} eq 'min_age' } $event_columns->@* ),
      'events table has min_age column';
    ok scalar( grep { $_->{column_name} eq 'max_age' } $event_columns->@* ),
      'events table has max_age column';
    ok scalar( grep { $_->{column_name} eq 'capacity' } $event_columns->@* ),
      'events table has capacity column';

    # Verify original columns still exist
    ok scalar( grep { $_->{column_name} eq 'time' } $event_columns->@* ),
      'events table still has time column';
    ok scalar( grep { $_->{column_name} eq 'duration' } $event_columns->@* ),
      'events table still has duration column';
    ok scalar( grep { $_->{column_name} eq 'location_id' } $event_columns->@* ),
      'events table still has location_id column';
    ok scalar( grep { $_->{column_name} eq 'teacher_id' } $event_columns->@* ),
      'events table still has teacher_id column';
}

# 3. Test the sessions table enhancements
{
    my $session_columns = $db->query(
        q{
        SELECT column_name, data_type
        FROM information_schema.columns
        WHERE table_name = 'sessions'
    }
    )->hashes;

    # Check for summer camp fields
    ok
      scalar( grep { $_->{column_name} eq 'session_type' }
          $session_columns->@* ),
      'sessions table has session_type column';
    ok
      scalar( grep { $_->{column_name} eq 'start_date' } $session_columns->@* ),
      'sessions table has start_date column';
    ok scalar( grep { $_->{column_name} eq 'end_date' } $session_columns->@* ),
      'sessions table has end_date column';
    ok scalar( grep { $_->{column_name} eq 'status' } $session_columns->@* ),
      'sessions table has status column';
}

# 4. Test the session_teachers table exists
{
    my $tables = $db->query(
        q{
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = 'registry' AND table_type = 'BASE TABLE'
    }
    )->arrays->map( sub { $_->[0] } )->to_array;

    ok scalar( grep { $_ eq 'session_teachers' } @$tables ),
      'session_teachers table exists';

    my $columns = $db->query(
        q{
        SELECT column_name, data_type
        FROM information_schema.columns
        WHERE table_name = 'session_teachers'
    }
    )->hashes;

    ok scalar( grep { $_->{column_name} eq 'session_id' } $columns->@* ),
      'session_teachers table has session_id column';
    ok scalar( grep { $_->{column_name} eq 'teacher_id' } $columns->@* ),
      'session_teachers table has teacher_id column';
}

# 5. Test the original session_events table still exists
{
    my $tables = $db->query(
        q{
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = 'registry' AND table_type = 'BASE TABLE'
    }
    )->arrays->map( sub { $_->[0] } )->to_array;

    ok scalar( grep { $_ eq 'session_events' } @$tables ),
      'session_events table still exists';
}

# 6. Test the pricing table exists
{
    my $tables = $db->query(
        q{
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = 'registry' AND table_type = 'BASE TABLE'
    }
    )->arrays->map( sub { $_->[0] } )->to_array;

    ok scalar( grep { $_ eq 'pricing' } @$tables ), 'pricing table exists';

    my $columns = $db->query(
        q{
        SELECT column_name, data_type
        FROM information_schema.columns
        WHERE table_name = 'pricing'
    }
    )->hashes;

    ok scalar( grep { $_->{column_name} eq 'session_id' } $columns->@* ),
      'pricing table has session_id column';
    ok scalar( grep { $_->{column_name} eq 'amount' } $columns->@* ),
      'pricing table has amount column';
    ok scalar( grep { $_->{column_name} eq 'early_bird_amount' } $columns->@* ),
      'pricing table has early_bird_amount column';
    ok scalar( grep { $_->{column_name} eq 'sibling_discount' } $columns->@* ),
      'pricing table has sibling_discount column';
}

# 7. Test the enrollments table exists
{
    my $tables = $db->query(
        q{
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = 'registry' AND table_type = 'BASE TABLE'
    }
    )->arrays->map( sub { $_->[0] } )->to_array;

    ok scalar( grep { $_ eq 'enrollments' } @$tables ),
      'enrollments table exists';

    my $columns = $db->query(
        q{
        SELECT column_name, data_type
        FROM information_schema.columns
        WHERE table_name = 'enrollments'
    }
    )->hashes;

    ok scalar( grep { $_->{column_name} eq 'session_id' } $columns->@* ),
      'enrollments table has session_id column';
    ok scalar( grep { $_->{column_name} eq 'student_id' } $columns->@* ),
      'enrollments table has student_id column';
    ok scalar( grep { $_->{column_name} eq 'status' } $columns->@* ),
      'enrollments table has status column';
}

# 8. Test constraints
{
    # Test status check constraint on sessions
    eval {
        $db->query(
"INSERT INTO sessions (name, slug, status) VALUES ('Invalid Status Test', 'invalid-status-test', 'invalid_status')"
        );
    };
    ok $@, 'Check constraint prevents invalid status values for sessions';

    # Test status check constraint on enrollments
    eval {
        $db->query(
"INSERT INTO enrollments (session_id, student_id, status) VALUES ('12345678-1234-1234-1234-123456789012', '12345678-1234-1234-1234-123456789012', 'invalid_status')"
        );
    };
    ok $@, 'Check constraint prevents invalid status values for enrollments';

    # Test uniqueness constraint for session teachers
    my $session = $dao->create(
        'Registry::DAO::Session',
        {
            name => 'Constraint Test Session'
        }
    );
    my $teacher = $dao->create(
        'Registry::DAO::User',
        {
            username => 'constraint_test_teacher',
            password => 'password123'
        }
    );

    # Insert first teacher assignment
    $db->query(
        "INSERT INTO session_teachers (session_id, teacher_id) VALUES (?, ?)",
        $session->id, $teacher->id );

    # Try to insert duplicate
    eval {
        $db->query(
"INSERT INTO session_teachers (session_id, teacher_id) VALUES (?, ?)",
            $session->id, $teacher->id
        );
    };
    ok $@,
      'Uniqueness constraint prevents duplicate session teacher assignments';
}
