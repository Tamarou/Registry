use 5.40.2;
use App::Sqitch ();
use Test::PostgreSQL ();

package Test::Registry::DB {

    sub new {
        my $class = shift;
        my $self = bless {}, $class;
        $self->{pgsql} = Test::PostgreSQL->new();
        App::Sqitch->new()->run( 'sqitch', 'deploy', '-t', $self->{pgsql}->uri );
        $ENV{DB_URL} = $self->{pgsql}->uri;
        return $self;
    }

    sub new_test_db ($) {
        state $pgsql = Test::PostgreSQL->new();
        App::Sqitch->new()->run( 'sqitch', 'deploy', '-t', $pgsql->uri );
        $ENV{DB_URL} = $pgsql->uri;
        return $pgsql->uri;
    }

    sub db {
        my $self = shift;
        return $self->{pgsql};
    }

    sub uri {
        my $self = shift;
        return $self->{pgsql}->uri;
    }

    sub setup_test_database {
        my $self = shift;
        require Registry::DAO;
        return Registry::DAO->new(url => $self->uri);
    }

    sub deploy_sqitch_changes {
        my ($self, $changes) = @_;
        for my $change (@$changes) {
            App::Sqitch->new()->run('sqitch', 'deploy', '-t', $self->uri, $change);
        }
    }
}