use 5.40.0;
use lib          qw(lib t/lib);
use experimental qw(defer builtin);

use Test::Mojo;
use Test::More import => [qw( done_testing ok $TODO )];
defer { done_testing };

TODO: {
    our $TODO = "Implement project creation workflow tests";

    ok 0, 'Test basic project creation with name';
    ok 0, 'Test project creation with customer context';
    ok 0, 'Test project creation with curriculum/materials';
    ok 0, 'Verify project is created in correct customer schema';
}
