use 5.40.0;
use lib          qw(lib t/lib);
use experimental qw(defer builtin);

use Test::Mojo;
use Test::More import => [qw( done_testing ok todo )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;

TODO: {
    our $TODO = "Implement Morgan's session management workflow";

    ok 0, 'Schedule recurring sessions';
    ok 0, 'Assign appropriate locations based on needs';
    ok 0, 'Handle session capacity and waitlists';
    ok 0, 'Resolve scheduling conflicts';
}
