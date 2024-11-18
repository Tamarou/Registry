use 5.40.0;
use lib          qw(lib t/lib);
use experimental qw(defer builtin);

use Test::Mojo;
use Test::More import => [qw( done_testing ok todo )];

defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;

TODO: {
    our $TODO = "Implement location creation workflow tests";

    ok 0, 'Test basic location creation with name';
    ok 0, 'Test location creation with customer context';
    ok 0, 'Test location creation with metadata (capacity, equipment)';
    ok 0, 'Verify location is created in correct customer schema';
    ok 0, 'Test location creation from event workflow context';
}
