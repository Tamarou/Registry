use v5.34.0;
use App::Sqitch;
use Test::PostgreSQL;
use Registry::DAO;

package Test::Registry::Fixtures {
    use experimental qw(signatures);

    sub new ($class, %args) {
        bless { %args }, $class;
    }

    sub get_test_db () {
        state $pgsql = Test::PostgreSQL->new();
        App::Sqitch->new()->run( 'sqitch', 'deploy', '-t', $pgsql->uri );
        $ENV{DB_URL} = $pgsql->uri;
        Registry::DAO->new( url => $pgsql->uri );
    }
    
    sub create_tenant ($db, $data) {
        require Registry::DAO::Tenant;
        Registry::DAO::Tenant->create($db, $data);
    }
    
    sub create_location ($db, $data) {
        require Registry::DAO::Location;
        Registry::DAO::Location->create($db, $data);
    }
    
    sub create_project ($db, $data) {
        require Registry::DAO::Project;
        Registry::DAO::Project->create($db, $data);
    }
    
    sub create_session ($db, $data) {
        require Registry::DAO::Event;
        Registry::DAO::Session->create($db, $data);
    }
    
    sub create_event ($db, $data) {
        require Registry::DAO::Event;
        Registry::DAO::Event->create($db, $data);
    }
    
    sub create_user ($db, $data) {
        require Registry::DAO::User;
        # Only pass fields that exist in the users table (username, passhash, birth_date, user_type, grade, created_at)
        my $user_data = {
            username => $data->{username},
            password => $data->{password},
        };
        # Add optional user table fields
        $user_data->{user_type} = $data->{user_type} if $data->{user_type};
        $user_data->{birth_date} = $data->{birth_date} if $data->{birth_date};
        $user_data->{grade} = $data->{grade} if $data->{grade};
        Registry::DAO::User->create($db, $user_data);
    }
    
    sub create_pricing ($db, $data) {
        require Registry::DAO::PricingPlan;
        Registry::DAO::PricingPlan->create($db, $data);
    }
    
    sub create_enrollment ($db, $data) {
        require Registry::DAO::Enrollment;
        Registry::DAO::Enrollment->create($db, $data);
    }

}

1;
