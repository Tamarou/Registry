use 5.40.0;
use lib          qw(lib t/lib);
use experimental qw(defer builtin);

use Test::Mojo;
use Test::More import => [qw( done_testing ok todo )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;

TODO: {
    our $TODO = "Implement Morgan's curriculum development workflow";

    ok 0, 'Create new curriculum materials';
    ok 0, 'Organize materials into structured lessons';
    ok 0, 'Link materials to educational standards';
    ok 0, 'Share materials with teaching staff';
}
