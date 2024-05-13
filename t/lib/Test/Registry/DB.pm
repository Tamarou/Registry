use 5.38.0;
use App::Sqitch;
use Test::PostgreSQL;
use Registry::DAO;
use experimental qw(builtin);
use builtin 'export_lexically';

package Test::Registry::DB {

    sub new_test_db ($) {
        state $pgsql = Test::PostgreSQL->new();
        App::Sqitch->new()->run( 'sqitch', 'deploy', '-t', $pgsql->uri );
        $ENV{DB_URL} = $pgsql->uri;
        return $pgsql->uri;
    }
}

