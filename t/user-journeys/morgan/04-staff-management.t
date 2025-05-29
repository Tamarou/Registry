use 5.40.2;
use lib          qw(lib t/lib);
use experimental qw(defer builtin);

use Test::Mojo;
use Test::More import => [qw( done_testing ok todo )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;

TODO: {
    our $TODO = "Implement Morgan's staff management workflow";

    ok 0, 'Create and configure teacher accounts';
    ok 0, 'Assign teachers to specific sessions';
    ok 0, 'Set up role-based permissions';
    ok 0, 'Monitor and report on teacher activities';
}
