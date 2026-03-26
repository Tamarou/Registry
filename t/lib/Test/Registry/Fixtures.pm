use 5.42.0;
use App::Sqitch;
use Test::PostgreSQL;
use Registry::DAO;

package Test::Registry::Fixtures {


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
        my $tenant = Registry::DAO::Tenant->create($db, $data);

        # Automatically create the tenant schema by cloning from registry schema.
        # Use the raw db handle directly to ensure the query runs even in void context.
        # Only clone when the slug is a plain SQL identifier (no hyphens) that clone_schema
        # can use without quoting issues.
        if ($tenant->slug =~ /^[a-z_][a-z0-9_]*$/) {
            my $raw_db = $db isa Registry::DAO ? $db->db : $db;
            $raw_db->query('SELECT clone_schema(?)', $tenant->slug);
        }

        return $tenant;
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
