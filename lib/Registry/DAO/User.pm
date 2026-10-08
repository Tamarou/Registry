# ABOUTME: DAO for user accounts with profile data. Handles creation,
# ABOUTME: password hashing, and auth relationship accessors (passkeys, tokens, API keys).
use 5.42.0;
use Object::Pad;

class Registry::DAO::User :isa(Registry::DAO::Object) {
    use Carp         qw( carp croak );
    use Scalar::Util qw( blessed );
    use experimental 'keyword_any';

    use Crypt::Passphrase;

    # The roles users.check_user_type permits. Named here so change_role refuses
    # an unknown one with a sentence, rather than letting the CHECK constraint
    # reject it with a database error nobody can act on.
    our @USER_TYPES = qw( parent student staff admin );

    field $id :param :reader;
    field $username :param :reader;
    field $passhash :param :reader = '';
    field $name :param :reader = '';
    field $email :param :reader = '';
    field $birth_date :param :reader;
    field $user_type :param :reader = 'parent';
    field $grade :param :reader;
    field $created_at :param;
    field $email_verified_at :param :reader = undef;
    field $invite_pending :param :reader = 0;
    # NULL means active. A timestamp rather than a boolean because an offboarding
    # wants to record when, and because "active" as a flag invites being read as
    # "logged in".
    field $deactivated_at :param :reader = undef;

    sub table { 'users' }

    # WHERE for find() and list(), which hand-build their queries because they
    # join user_profiles and SQL::Abstract is not in that path.
    #
    # Hand-building is why these two diverged from every other find/list in
    # Registry: a filter value was bound straight into `= ?`, so the shapes the
    # rest of the DAO layer accepts became wrong answers here rather than errors.
    # Two of them:
    #
    #   { user_type => ['admin','staff'] }   the arrayref stringified to
    #                                        ARRAY(0x...) and matched no row
    #   { deactivated_at => undef }          bound `= NULL`, never true, so
    #                                        "who is active" answered "nobody"
    #
    # Neither raised anything. SQL::Abstract's semantics -- IN for a list, IS
    # NULL for undef -- are what callers already expect from the signature, so
    # those are what this gives them (#434).
    #
    # One builder, not a copy in each method. The copies are how the two came to
    # share a defect that had to be fixed in both places.
    sub _where_for ( $class, $filter ) {
        my ( @clauses, @binds );

        for my $key ( sort keys %$filter ) {
            # email and name live on user_profiles; everything else on users.
            my $col = ( $key eq 'email' || $key eq 'name' ) ? "up.$key" : "u.$key";
            my $value = $filter->{$key};

            if ( ref $value eq 'ARRAY' ) {
                unless (@$value) {
                    # IN () is a syntax error, not a result. An empty set of
                    # acceptable values accepts nothing, which is also what
                    # SQL::Abstract answers.
                    push @clauses, '1 = 0';
                    next;
                }
                push @clauses,
                    "$col IN (" . join( ', ', map { '?' } @$value ) . ')';
                push @binds, @$value;
                next;
            }

            unless ( defined $value ) {
                push @clauses, "$col IS NULL";
                next;
            }

            push @clauses, "$col = ?";
            push @binds, $value;
        }

        return ( \@clauses, \@binds );
    }

    sub find ( $class, $db, $filter, $order = { -desc => 'u.created_at' } ) {
        $db = $db->db if $db isa Registry::DAO;
        delete $filter->{password};
        
        # Join users and user_profiles tables to get complete user data
        my $query = q{
            SELECT u.id, u.username, u.passhash, u.birth_date, u.user_type, u.grade, u.created_at,
                   u.email_verified_at, u.invite_pending, u.deactivated_at,
                   up.email, up.name
            FROM users u
            LEFT JOIN user_profiles up ON u.id = up.user_id
        };
        
        my ( $where_clauses, $bind_params ) = $class->_where_for($filter);
        my @where_clauses = @$where_clauses;
        my @bind_params   = @$bind_params;

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

    # Like find, but returns every matching user as an arrayref of objects.
    # find() is hard-capped at LIMIT 1, so callers that need a collection
    # (e.g. listing staff for teacher assignment) use this instead.
    sub list ( $class, $db, $filter = {}, $order = { -desc => 'u.created_at' } ) {
        $db = $db->db if $db isa Registry::DAO;
        delete $filter->{password};

        my $query = q{
            SELECT u.id, u.username, u.passhash, u.birth_date, u.user_type, u.grade, u.created_at,
                   u.email_verified_at, u.invite_pending, u.deactivated_at,
                   up.email, up.name
            FROM users u
            LEFT JOIN user_profiles up ON u.id = up.user_id
        };

        my ( $where_clauses, $bind_params ) = $class->_where_for($filter);
        my @where_clauses = @$where_clauses;
        my @bind_params   = @$bind_params;

        if (@where_clauses) {
            $query .= ' WHERE ' . join( ' AND ', @where_clauses );
        }

        if ( ref $order eq 'HASH' && exists $order->{-desc} ) {
            my $col = $order->{-desc};
            $col = "u.$col" unless $col =~ /\./;
            $query .= " ORDER BY $col DESC";
        }

        return [ map { $class->new( $_->%* ) } $db->query( $query, @bind_params )->hashes->@* ];
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
            # invite_pending is on this list because signup sets it. The column
            # and its reader existed since passwordless-auth; nothing wrote it,
            # so it read false for everyone and "has this person been invited
            # yet" had no answer.
            my %user_data = map { $_ => $data->{$_} } 
                           grep { exists $data->{$_} } 
                           qw(username password birth_date user_type grade invite_pending);
            
            my %profile_data = map { $_ => $data->{$_} } 
                              grep { exists $data->{$_} } 
                              qw(email name phone data);

            if (defined $user_data{password}) {
                $user_data{passhash} = $crypt->hash_password(delete $user_data{password});
            } else {
                delete $user_data{password};  # ensure no stray key sent to DB
            }
            
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
    
    # Whether this account may be used at all.
    #
    # Checked on every authenticated request, at the single point both auth paths
    # pass through, so a deactivation takes effect on the offboarded person's very
    # next request rather than whenever their cookie happens to expire.
    method is_active { !defined $deactivated_at }

    # Revoke every way in. Deactivation rather than deletion, and not by choice:
    # events.teacher_id and attendance_records.marked_by are NOT NULL references
    # to this row, so the register that says who marked it is what holds a departed
    # teacher's account in place. Deleting would either be refused or destroy the
    # audit trail, and the trail is the more important of the two.
    #
    # Refuses two cases that would lock a tenant out of itself, because both are
    # unrecoverable without database access:
    #
    #   * deactivating yourself -- a solo operator is the whole tenant
    #   * deactivating the last active admin
    #
    # Returns the reactivated/deactivated object. Idempotent: deactivating an
    # already-deactivated account keeps the original timestamp, because when they
    # left is a fact and this call is not new information.
    method deactivate ( $db, $acting_user_id = undef ) {
        $db = $db->db if $db isa Registry::DAO;

        croak 'You cannot deactivate your own account'
            if defined $acting_user_id && $acting_user_id eq $id;

        if ( $user_type eq 'admin' && $self->is_active ) {
            my $other_admins = $db->query(
                q{SELECT COUNT(*) FROM users
                   WHERE user_type = 'admin' AND deactivated_at IS NULL AND id <> ?},
                $id )->array->[0];
            croak 'Cannot deactivate the last active administrator'
                unless $other_admins;
        }

        return $self unless $self->is_active;

        my $row = $db->query(
            'UPDATE users SET deactivated_at = now() WHERE id = ? AND deactivated_at IS NULL
              RETURNING *', $id )->hash;

        # Lost the race to another deactivation; the account is off either way.
        return $self unless $row;
        return __CLASS__->new(%$row);
    }

    # Change an existing account's role.
    #
    # user_type could be set when an account was created and never again: no
    # screen, no route, no DAO path (#424). Promoting a teacher to administrator,
    # or de-privileging someone who has left without deleting the account and
    # orphaning events.teacher_id and attendance_records.marked_by, both needed
    # database access.
    #
    # The guards mirror deactivate's, because the failure modes are the same
    # lockout by a different route:
    #
    #   * Only an admin may grant admin. This is the rule CreateUser already
    #     enforces, and it has to hold here too -- the people screen is open to
    #     admin AND staff, so without it a staff member could mint themselves an
    #     administrator.
    #   * The last active administrator cannot be demoted, exactly as they
    #     cannot be deactivated.
    #   * Nobody changes their own role. Demoting yourself out of admin cannot be
    #     undone from inside the product, which is deactivate's reasoning for
    #     refusing self-deactivation.
    #
    # Croaks with a sentence meant for a person: the controller shows these
    # verbatim, because each refusal needs a different response from the operator.
    method change_role ( $db, $new_type, $acting_user = undef ) {
        $db = $db->db if $db isa Registry::DAO;

        croak "'$new_type' is not a role"
            unless any { $_ eq ( $new_type // '' ) } @USER_TYPES;

        my $acting_id = ref $acting_user
            ? ( blessed($acting_user) ? $acting_user->id : $acting_user->{id} )
            : $acting_user;

        croak 'You cannot change your own role'
            if defined $acting_id && $acting_id eq $id;

        # Idempotent, and checked before the privilege gate: re-asserting the
        # role an account already has is not a grant.
        return $self if $new_type eq $user_type;

        if ( $new_type eq 'admin' ) {
            my $acting_type = $self->_role_of( $db, $acting_id );
            croak 'Only an administrator can make someone an administrator'
                unless ( $acting_type // '' ) eq 'admin';
        }

        if ( $user_type eq 'admin' && $self->is_active ) {
            my $other_admins = $db->query(
                q{SELECT COUNT(*) FROM users
                   WHERE user_type = 'admin' AND deactivated_at IS NULL AND id <> ?},
                $id )->array->[0];
            croak 'Cannot demote the last active administrator'
                unless $other_admins;
        }

        my $row = $db->query(
            'UPDATE users SET user_type = ? WHERE id = ? RETURNING *',
            $new_type, $id )->hash or return $self;

        return __CLASS__->new(%$row);
    }

    # The acting user's role read from the row, not from the session. A session
    # carries whatever it was given; the privilege gate has to turn on what the
    # database says the caller is.
    method _role_of ( $db, $acting_id ) {
        return undef unless defined $acting_id;
        my $row = $db->query(
            'SELECT user_type FROM users WHERE id = ?', $acting_id )->hash;
        return $row && $row->{user_type};
    }

    # Clears the invite_pending flag, once an invitation has actually been sent.
    method mark_invited ($db) {
        $db = $db->db if $db isa Registry::DAO;
        return $self unless $invite_pending;

        my $row = $db->query(
            'UPDATE users SET invite_pending = false WHERE id = ? RETURNING *', $id
        )->hash or return $self;

        return __CLASS__->new(%$row);
    }

    method reactivate ($db) {
        $db = $db->db if $db isa Registry::DAO;
        my $row = $db->query(
            'UPDATE users SET deactivated_at = NULL WHERE id = ? RETURNING *', $id )->hash;
        return $row ? __CLASS__->new(%$row) : $self;
    }

    method check_password ($password) {
        return 0 unless $password && $passhash;
        
        my $crypt = Crypt::Passphrase->new(
            encoder    => 'Argon2',
            validators => [ 'Bcrypt', 'SHA1::Hex' ],
        );
        
        return $crypt->verify_password($password, $passhash);
    }

    method passkeys ($db) {
        require Registry::DAO::Passkey;
        Registry::DAO::Passkey->for_user($db, $id);
    }

    method magic_link_tokens ($db) {
        require Registry::DAO::MagicLinkToken;
        Registry::DAO::MagicLinkToken->find($db, { user_id => $id });
    }

    method api_keys ($db) {
        require Registry::DAO::ApiKey;
        Registry::DAO::ApiKey->find($db, { user_id => $id });
    }

}