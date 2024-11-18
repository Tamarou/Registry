use 5.40.0;
use lib          qw(lib t/lib);
use experimental qw(defer builtin);

use Test::Mojo;
use Test::More import => [qw( done_testing ok todo )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;

TODO: {
    our $TODO = "Implement Nancy's program discovery workflow";

    ok 0, 'Browse available after-school programs';
    ok 0, 'Filter programs by age group and interests';
    ok 0, 'View program details and requirements';
    ok 0, 'Check program schedules and availability';
    ok 0, 'Review program safety policies and staff credentials';
}
