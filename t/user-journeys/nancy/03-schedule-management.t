use 5.40.0;
use lib          qw(lib t/lib);
use experimental qw(defer builtin);

use Test::Mojo;
use Test::More import => [qw( done_testing ok todo )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;

TODO: {
    our $TODO = "Implement Nancy's schedule management workflow";

    ok 0, 'View consolidated schedule for all children';
    ok 0, 'Receive notifications about schedule changes';
    ok 0, 'Request schedule adjustments';
    ok 0, 'Mark attendance exceptions (absences/early pickup)';
    ok 0, 'Coordinate with other authorized guardians';
}
