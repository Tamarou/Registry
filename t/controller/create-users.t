use 5.40.0;
use lib          qw(lib t/lib);
use experimental qw(defer builtin);

use Test::Mojo;
use Test::More import => [qw( done_testing ok todo )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;

TODO: {
    our $TODO = "Implement user creation workflow tests";

    ok 0, 'Test basic user creation with username/password';
    ok 0, 'Test user creation with customer context';
    ok 0, 'Verify user is created in correct customer schema';
}
