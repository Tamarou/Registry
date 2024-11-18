use 5.40.0;
use lib          qw(lib t/lib);
use experimental qw(defer builtin);

use Test::Mojo;
use Test::More import => [qw( done_testing ok todo )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;

TODO: {
    our $TODO = "Implement Nancy's communication workflow";

    ok 0, 'View program announcements and updates';
    ok 0, 'Message program staff directly';
    ok 0, 'Receive progress reports and feedback';
    ok 0, 'Update contact preferences';
    ok 0, 'Access incident reports and notifications';
}
