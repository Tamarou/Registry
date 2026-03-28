#!/usr/bin/env perl
# ABOUTME: Tests that auth-related email templates render correctly with
# ABOUTME: expected content for magic links, invitations, verification, and passkey notices.
use 5.42.0;
use warnings;
use utf8;

use Test::More;

use lib qw(lib t/lib);

use Registry::Email::Template;

my %test_vars = (
    tenant_name      => 'Dance Stars Academy',
    magic_link_url   => 'https://dance-stars.com/auth/magic/abc123',
    expires_in_hours => 24,
    inviter_name     => 'Jordan Smith',
    role             => 'instructor',
    verification_url => 'https://dance-stars.com/auth/verify-email/xyz789',
    device_name      => 'MacBook Pro',
);

for my $template_name (qw(magic_link_login magic_link_invite email_verification passkey_registered passkey_removed)) {
    subtest "Template: $template_name" => sub {
        my $result = Registry::Email::Template->render($template_name, %test_vars);
        ok($result, "Rendered $template_name");
        ok($result->{html}, 'Has HTML output');
        ok($result->{text}, 'Has text output');
        like($result->{html}, qr/Dance Stars Academy/, 'HTML contains tenant name');
        like($result->{text}, qr/Dance Stars Academy/, 'Text contains tenant name');
    };
}

subtest 'magic_link_login contains sign-in link' => sub {
    my $result = Registry::Email::Template->render('magic_link_login', %test_vars);
    like($result->{html}, qr{auth/magic/abc123}, 'HTML contains magic link URL');
    like($result->{text}, qr{auth/magic/abc123}, 'Text contains magic link URL');
};

subtest 'magic_link_invite contains inviter and role' => sub {
    my $result = Registry::Email::Template->render('magic_link_invite', %test_vars);
    like($result->{html}, qr/Jordan Smith/, 'HTML contains inviter name');
    like($result->{html}, qr/instructor/, 'HTML contains role');
};

done_testing();
