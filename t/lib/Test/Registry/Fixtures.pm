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
        require Registry::DAO::Session;
        Registry::DAO::Session->create($db, $data);
    }
    
    sub create_event ($db, $data) {
        require Registry::DAO::Event;
        Registry::DAO::Event->create($db, $data);
    }
    
    sub create_user ($db, $data) {
        require Registry::DAO::User;
        # Pass all provided data - User.pm will properly separate fields for users and user_profiles tables
        Registry::DAO::User->create($db, $data);
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
