use 5.40.2;
use Object::Pad;

class Registry::DAO::User :isa(Registry::DAO::Object) {
    use Carp         qw( carp );
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

    use constant table => 'users';

    sub find ( $class, $db, $filter, $order = { -desc => 'created_at' } ) {
        delete $filter->{password};
        my $data =
          $db->select( $class->table, '*', $filter, $order )->expand->hash;

        return $data ? $class->new( $data->%* ) : ();
    }

    sub create ( $class, $db, $data //= carp "must provide data" ) {
        try {
            my $crypt = Crypt::Passphrase->new(
                encoder    => 'Argon2',
                validators => [ 'Bcrypt', 'SHA1::Hex' ],
            );

            $data->{passhash} =
              $crypt->hash_password( delete $data->{password} );
            my %data =
              $db->insert( $class->table, $data, { returning => '*' } )
              ->hash->%*;
            return $class->new(%data);
        }
        catch ($e) {
            carp "Error creating $class: $e";
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