#!/usr/bin/env perl
# ABOUTME: Integration test for the full magic link flow: request a link,
# ABOUTME: consume it, verify session is established, access protected routes.
use 5.42.0;
use warnings;
use utf8;

use Test::More;
use Test::Mojo;

use lib qw(lib t/lib);
use Test::Registry::DB;

use Registry::DAO::User;
use Registry::DAO::MagicLinkToken;
use Registry::DAO::Workflow;
use Mojo::Home;
use YAML::XS qw(Load);

my $tdb = Test::Registry::DB->new;
my $dao = $tdb->db;
my $db  = $dao->db;

# Import workflows so route redirects resolve properly
my $wf_dir = Mojo::Home->new->child('workflows');
for my $file ( $wf_dir->list_tree->grep(qr/\.ya?ml$/)->each ) {
    my $data = Load( $file->slurp );
    next if $data->{draft};
    Registry::DAO::Workflow->from_yaml( $dao, $file->slurp );
}

my $user = Registry::DAO::User->create($db, {
    username  => 'integration_auth_user',
    email     => 'integration@example.com',
    name      => 'Integration Tester',
    user_type => 'admin',
    password  => 'test_password',
});

subtest 'Full magic link login flow' => sub {
    my $t = Test::Mojo->new('Registry');

    # Generate a token (simulating what request_magic_link does)
    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db, {
        user_id => $user->id,
        purpose => 'login',
    });

    ok($token_obj, 'Token generated successfully');
    ok($plaintext,  'Plaintext token returned');

    # Consume the magic link
    $t->get_ok("/auth/magic/$plaintext")
      ->status_is(302, 'Magic link redirects after consuming token');

    # Session should now be established - access a protected route
    # The admin dashboard requires admin role, and the user is admin type
    $t->get_ok('/admin/dashboard')
      ->status_isnt(401, 'Can access protected route after magic link login')
      ->status_isnt(302, 'Not redirected to login after magic link login');

    # Get CSRF token by fetching an HTML page that contains one
    $t->get_ok('/auth/login');
    my $csrf_input = $t->tx->res->dom->at('input[name="csrf_token"]');
    my $csrf_token = $csrf_input ? $csrf_input->attr('value') : '';

    # Logout (requires CSRF token since it's a POST)
    $t->post_ok('/auth/logout' => form => { csrf_token => $csrf_token })
      ->status_is(302, 'Logout redirects');

    # Should now be rejected from protected routes
    my $status = $t->get_ok('/admin/dashboard')->tx->res->code;
    ok($status == 302 || $status == 401 || $status == 403,
        "Redirected or denied after logout (got $status)");
};

subtest 'Invalid magic link token returns error' => sub {
    my $t = Test::Mojo->new('Registry');

    $t->get_ok('/auth/magic/thisisnotavalidtoken')
      ->status_isnt(302, 'Invalid token does not redirect to success');
};

subtest 'Consumed magic link cannot be reused' => sub {
    my $t = Test::Mojo->new('Registry');

    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($db, {
        user_id => $user->id,
        purpose => 'login',
    });

    # First use
    $t->get_ok("/auth/magic/$plaintext")
      ->status_is(302, 'First use succeeds with redirect');

    # Second use of the same token
    $t->get_ok("/auth/magic/$plaintext")
      ->status_isnt(302, 'Second use of same token does not redirect to success');
};

done_testing();
