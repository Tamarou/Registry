# ABOUTME: Tests that the tenant signup workflow creates users without passwords
# ABOUTME: and that team member invites use magic link tokens instead of temp passwords.
use 5.42.0;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw( done_testing is ok like unlike is_deeply subtest use_ok can_ok )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Mojo::File qw(curfile);

my $test_db = Test::Registry::DB->new();
my $dao = $test_db->db;

subtest 'users.html.ep has no password field' => sub {
    my $root = curfile->dirname->dirname->dirname;
    my $content = $root->child('templates/tenant-signup/users.html.ep')->slurp;

    unlike($content, qr/admin_password/,
        'users.html.ep does not have admin_password field');
    unlike($content, qr/type="password"/,
        'users.html.ep does not have any password input');
    like($content, qr/admin_email/,
        'users.html.ep still has admin_email field');
    like($content, qr/admin_username/,
        'users.html.ep still has admin_username field');
};

subtest 'complete.html.ep has passkey registration prompt' => sub {
    my $root = curfile->dirname->dirname->dirname;
    my $content = $root->child('templates/tenant-signup/complete.html.ep')->slurp;

    like($content, qr/passkey|webauthn|passkey-setup/i,
        'complete.html.ep has passkey registration section');
    unlike($content, qr/password you created during signup/i,
        'complete.html.ep does not reference password created during signup');
};

subtest 'RegisterTenant does not have _generate_temp_password method' => sub {
    use_ok('Registry::DAO::WorkflowSteps::RegisterTenant');

    ok(
        !Registry::DAO::WorkflowSteps::RegisterTenant->can('_generate_temp_password'),
        'RegisterTenant does not have _generate_temp_password method'
    );
};

subtest 'RegisterTenant still has required methods' => sub {
    use_ok('Registry::DAO::WorkflowSteps::RegisterTenant');

    can_ok('Registry::DAO::WorkflowSteps::RegisterTenant', 'process');
    can_ok('Registry::DAO::WorkflowSteps::RegisterTenant', '_format_trial_end_date');
    can_ok('Registry::DAO::WorkflowSteps::RegisterTenant', '_send_invitation_email');
};
