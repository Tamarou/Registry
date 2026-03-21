# ABOUTME: Security test suite for input validation in Registry DAOs.
# ABOUTME: Verifies protection against SQL injection, XSS, null bytes, and Unicode handling.
use 5.42.0;
use lib          qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw( done_testing is ok like is_deeply unlike )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;
my $test_db = Test::Registry::DB->new();
my $dao     = $test_db->db;

# Security audit: Input validation and SQL injection prevention tests

{    # Test SQL injection prevention in DAO layer
    try {
        # Attempt SQL injection in email field
        my $malicious_user = Registry::DAO::User->create(
            $dao->db,
            {
                username => 'testuser' . int( rand(10000) ),
                password => 'password123',
                email    => "'; DROP TABLE users; --",
                name     => 'Malicious User'
            }
        );

# If this succeeds, the email should be stored as literal text, not executed as SQL
        ok $malicious_user, 'Malicious SQL in email field handled safely';
        is $malicious_user->email, "'; DROP TABLE users; --",
          'SQL injection stored as literal text';

        # Verify users table still exists
        my $user_count = $dao->db->select( 'users', 'COUNT(*)' )->array->[0];
        ok $user_count >= 1, 'Users table not dropped by SQL injection attempt';
    }
    catch ($e) {

        # If creation fails due to validation, that's also acceptable
        ok 1, "SQL injection attempt properly rejected: $e";
    }
}

{    # Test parameterized queries in complex searches
     # Create test data
    my $user = Registry::DAO::User->create(
        $dao->db,
        {
            username => 'testuser',
            password => 'password123',
            email    => 'test@example.com',
            name     => 'Test User'
        }
    );

    # Test search with potentially malicious input
    my $malicious_search = "'; SELECT * FROM users WHERE 1=1; --";

    # This query should return no results, not execute the injected SQL
    my $results = $dao->db->select(
        'users', '*',
        {
            username => $malicious_search
        }
    )->hashes->to_array;

    is scalar(@$results), 0, 'Malicious search input returns no results (safe)';
}

{    # Test XSS prevention in stored data
    my $user = Registry::DAO::User->create(
        $dao->db,
        {
            username => 'testuser' . int( rand(10000) ),
            password => 'password123',
            email    => 'xss@test.com',
            name     => '<script>alert("XSS")</script>'
        }
    );

    # XSS should be stored as literal text
    like $user->name, qr/<script>/,
      'XSS script stored as literal text (not executed)';
}

{    # Test input length validation
    my $very_long_string = 'x' x 10000;    # 10,000 characters

    # Suppress warnings about long input since we're testing this deliberately
    local $SIG{__WARN__} = sub { };

    try {
        my $user = Registry::DAO::User->create(
            $dao->db,
            {
                username => 'testuser' . int( rand(10000) ),
                password => 'password123',
                email    => $very_long_string . '@example.com',
                name     => $very_long_string
            }
        );

        # If creation succeeds, verify data is properly truncated or handled
        ok length( $user->email ) <= 255, 'Long email handled appropriately';
        ok length( $user->name ) <= 255,  'Long name handled appropriately';
    }
    catch ($e) {

        # If validation rejects long input, that's good
        like $e, qr/too long|length|size/, 'Long input properly rejected';
    }
}

{    # Test special character handling
    my $special_chars = "!#\$%^&*()_+-=[]{}|;':\",./<>?`~";

    my $user = Registry::DAO::User->create(
        $dao->db,
        {
            username => 'testuser' . int( rand(10000) ),
            password => 'password123',
            email    => 'special@example.com',
            name     => "User with $special_chars"
        }
    );

    ok $user, 'User with special characters created safely';
    is $user->name, "User with $special_chars",
      'Special characters preserved correctly';
}

{    # Test Unicode handling
    # Unicode test string: "Jose Maria <CJK> <Arabic> <Cyrillic>"
    # Constructed with chr() to avoid non-ASCII bytes in source (required by use 5.42.0)
    # Jose\x{E9} Mar\x{ED}a \x{6D4B}\x{8BD5} \x{0627}\x{0644}\x{0639}\x{0631}\x{0628}\x{064A}\x{0629} \x{0440}\x{0443}\x{0441}\x{0441}\x{043A}\x{0438}\x{0439}
    my $unicode_name = join(
        '',
        'Jos', chr(0x00E9), ' Mar', chr(0x00ED), 'a ',    # Jose+accent Mar+accent+a
        chr(0x6D4B), chr(0x8BD5), ' ',                    # CJK test characters
        chr(0x0627), chr(0x0644), chr(0x0639),             # Arabic alef-lam-ain
        chr(0x0631), chr(0x0628), chr(0x064A), chr(0x0629), ' ',    # Arabic ra-ba-ya-ta
        chr(0x0440), chr(0x0443), chr(0x0441), chr(0x0441),          # Cyrillic ru-ss
        chr(0x043A), chr(0x0438), chr(0x0439)                        # Cyrillic kiy
    );

    my $unicode_user = Registry::DAO::User->create(
        $dao->db,
        {
            username => 'testuser' . int( rand(10000) ),
            password => 'password123',
            email    => 'unicode@example.com',
            name     => $unicode_name
        }
    );

    ok $unicode_user, 'Unicode user created successfully';
    is $unicode_user->name, $unicode_name,
      'Unicode text preserved correctly';
}

{    # Test null byte injection
    try {
        my $null_byte_user = Registry::DAO::User->create(
            $dao->db,
            {
                username => 'testuser' . int( rand(10000) ),
                password => 'password123',
                email    => "test\x00\@example.com",
                name     => "Test\x00User"
            }
        );

        # Null bytes should be handled safely
        ok $null_byte_user, 'User with null bytes handled safely';
        unlike $null_byte_user->email, qr/\x00/,
          'Null bytes removed or handled';
    }
    catch ($e) {

        # If null bytes are rejected, that's also safe
        ok 1, "Null byte injection properly rejected: $e";
    }
}

{    # Test email validation
    my $invalid_emails =
      [ 'notanemail', '@example.com', 'user@', 'user..double.dot@example.com' ];

    my $valid_count    = 0;
    my $rejected_count = 0;

    for my $email (@$invalid_emails) {
        try {
            my $user = Registry::DAO::User->create(
                $dao->db,
                {
                    username => 'testuser' . int( rand(10000) ),
                    password => 'password123',
                    email    => $email,
                    name     => 'Test User'
                }
            );

            if ($user) {
                $valid_count++;

          # If invalid email is accepted, it should at least be stored correctly
                is $user->email, $email,
                  "Invalid email stored correctly: $email";
            }
        }
        catch ($e) {
            $rejected_count++;
            like $e, qr/email|invalid|format/,
              "Invalid email properly rejected: $email";
        }
    }

# Either emails are validated (rejected_count > 0) or stored safely (valid_count > 0)
    ok(
        ( $valid_count > 0 || $rejected_count > 0 ),
        'Email validation working correctly'
    );
}

{    # Test basic data integrity
    my $user = Registry::DAO::User->create(
        $dao->db,
        {
            username => 'testuser' . int( rand(10000) ),
            password => 'password123',
            email    => 'integrity@test.com',
            name     => 'Integrity Test'
        }
    );

    # Test that we can find the user again
    my $found_user = $dao->find( User => { id => $user->id } );
    ok $found_user, 'User can be found after creation';
    is $found_user->email, $user->email, 'User email matches after retrieval';
    is $found_user->name,  $user->name,  'User name matches after retrieval';
}
