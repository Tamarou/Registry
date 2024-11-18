use 5.40.0;
use lib          qw(lib t/lib);
use experimental qw(defer builtin);

use Test::Mojo;
use Test::More import => [qw( done_testing ok todo )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;

TODO: {
    our $TODO = "Implement Nancy's enrollment workflow";

    ok 0, 'Create family account and add children';
    ok 0, 'Submit enrollment applications';
    ok 0, 'Provide required documentation';
    ok 0, 'Complete emergency contact information';
    ok 0, 'Process program payments';
}
