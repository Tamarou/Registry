use 5.40.0;
use App::Sqitch;
use Test::PostgreSQL;
use Registry::DAO;

package Test::Registry::Fixtures {

    sub get_test_db () {
        state $pgsql = Test::PostgreSQL->new();
        App::Sqitch->new()->run( 'sqitch', 'deploy', '-t', $pgsql->uri );
        $ENV{DB_URL} = $pgsql->uri;
        Registry::DAO->new( url => $pgsql->uri );
    }

}
