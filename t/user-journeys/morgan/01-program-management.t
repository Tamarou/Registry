use 5.40.2;
use lib          qw(lib t/lib);
use experimental qw(defer builtin);

use Test::Mojo;
use Test::More import => [qw( done_testing ok todo )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;

TODO: {
    our $TODO = "Implement Morgan's program management workflow";

    ok 0, 'Create new educational program with curriculum and schedule';
    ok 0, 'Update existing program details';
    ok 0, 'Assign teachers to program';
    ok 0, 'Set and modify program schedule';
}
