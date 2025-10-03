use 5.40.2;
use Object::Pad;

class Registry::DAO::User :isa(Registry::DAO::Object) {
    use Carp         qw( carp croak );
    use experimental qw(try);
    use Crypt::Passphrase;

    field $id :param :reader;
    field $username :param :reader;
    field $passhash :param :reader = '';
    field $name :param :reader = '';
    field $email :param :reader = '';
    field $birth_date :param :reader;
    field $user_type :param :reader = 'parent';
    field $grade :param :reader;
    field $created_at :param;

    sub table { 'users' }

    sub find ( $class, $db, $filter, $order = { -desc => 'u.created_at' } ) {
        $db = $db->db if $db isa Registry::DAO;
        delete $filter->{password};
        
        # Join users and user_profiles tables to get complete user data
        my $query = q{
            SELECT u.id, u.username, u.passhash, u.birth_date, u.user_type, u.grade, u.created_at,
                   up.email, up.name
            FROM users u
            LEFT JOIN user_profiles up ON u.id = up.user_id
        };
        
        my @where_clauses = ();
        my @bind_params = ();
        
        # Build WHERE clause from filter
        for my $key (keys %$filter) {
            if ($key eq 'email' || $key eq 'name') {
                push @where_clauses, "up.$key = ?";
            } else {
                push @where_clauses, "u.$key = ?";
            }
            push @bind_params, $filter->{$key};
        }
        
        if (@where_clauses) {
            $query .= ' WHERE ' . join(' AND ', @where_clauses);
        }
        
        # Add order by clause
        if (ref $order eq 'HASH' && exists $order->{-desc}) {
            my $col = $order->{-desc};
            $col = "u.$col" unless $col =~ /\./;
            $query .= " ORDER BY $col DESC";
        }
        
        $query .= ' LIMIT 1';
        
        my $data = $db->query($query, @bind_params)->hash;
        return $data ? $class->new( $data->%* ) : ();
    }

    sub create ( $class, $db, $data //= carp "must provide data" ) {
        $db = $db->db if $db isa Registry::DAO;
        
        # Check for tenant context to use schema-qualified table names
        my $tenant_slug = delete $data->{__tenant_slug};
        my $users_table = 'users';
        my $profiles_table = 'user_profiles';
        
        if ($tenant_slug) {
            $users_table = "$tenant_slug.users";
            $profiles_table = "$tenant_slug.user_profiles";
        }
        
        try {
            my $crypt = Crypt::Passphrase->new(
                encoder    => 'Argon2',
                validators => [ 'Bcrypt', 'SHA1::Hex' ],
            );

            # Separate data for users and user_profiles tables
            my %user_data = map { $_ => $data->{$_} } 
                           grep { exists $data->{$_} } 
                           qw(username password birth_date user_type grade);
            
            my %profile_data = map { $_ => $data->{$_} } 
                              grep { exists $data->{$_} } 
                              qw(email name phone data);

            $user_data{passhash} = $crypt->hash_password( delete $user_data{password} );
            
            # Validate input lengths for security
            if (exists $profile_data{email} && defined $profile_data{email} && length($profile_data{email}) > 255) {
                croak "Email address is too long (maximum 255 characters)";
            }
            if (exists $profile_data{name} && defined $profile_data{name} && length($profile_data{name}) > 255) {
                croak "Name is too long (maximum 255 characters)";
            }
            if (exists $user_data{username} && defined $user_data{username} && length($user_data{username}) > 255) {
                croak "Username is too long (maximum 255 characters)";
            }
            
            # Start transaction for atomic insert
            my $tx = $db->begin;
            
            # Insert into users table (potentially schema-qualified)
            my $result = $db->insert( $users_table, \%user_data, { returning => '*' } );
            
            my $user = $result->hash;
            
            # Insert into user_profiles table if we have profile data
            my $profile = {};
            if (%profile_data) {
                $profile_data{user_id} = $user->{id};
                $profile = $db->insert( $profiles_table, \%profile_data, { returning => '*' } )->hash;
            }
            
            $tx->commit;
            
            # Combine the data for the object
            my %combined_data = ( $user->%*, $profile->%* );
            delete $combined_data{user_id}; # Remove the foreign key field
            
            return $class->new(%combined_data);
        }
        catch ($e) {
            carp "Error creating $class: $e";
            croak $e;
        };
    }
    
    method check_password ($password) {
        return 0 unless $password && $passhash;
        
        my $crypt = Crypt::Passphrase->new(
            encoder    => 'Argon2',
            validators => [ 'Bcrypt', 'SHA1::Hex' ],
        );
        
        return $crypt->verify_password($password, $passhash);
    }

}