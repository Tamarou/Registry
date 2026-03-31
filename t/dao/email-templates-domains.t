#!/usr/bin/env perl
# ABOUTME: Tests for domain verification email templates. Verifies that
# ABOUTME: domain_verified and domain_verification_failed render correctly.
use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Registry::Email::Template;

subtest 'domain_verified template renders' => sub {
    my $result = Registry::Email::Template->render('domain_verified',
        tenant_name => 'Dance Stars',
        domain      => 'dance-stars.com',
    );
    ok($result,           'domain_verified template produces output');
    ok($result->{html},   'domain_verified has HTML output');
    ok($result->{text},   'domain_verified has text output');
    like($result->{html}, qr/dance-stars\.com/, 'domain name appears in HTML');
    like($result->{html}, qr/Dance Stars/,      'tenant name appears in HTML');
    like($result->{text}, qr/dance-stars\.com/, 'domain name appears in text');
    like($result->{text}, qr/Dance Stars/,      'tenant name appears in text');
    like($result->{html}, qr/passkey|re-register/i,
        'passkey re-registration note present in domain_verified HTML');
    like($result->{text}, qr/passkey|re-register/i,
        'passkey re-registration note present in domain_verified text');
};

subtest 'domain_verification_failed template renders' => sub {
    my $result = Registry::Email::Template->render('domain_verification_failed',
        tenant_name => 'Dance Stars',
        domain      => 'dance-stars.com',
        error       => 'CNAME record not found',
        retry_url   => 'https://dance_stars.tinyartempire.com/admin/domains',
    );
    ok($result,           'domain_verification_failed template produces output');
    ok($result->{html},   'domain_verification_failed has HTML output');
    ok($result->{text},   'domain_verification_failed has text output');
    like($result->{html}, qr/dance-stars\.com/,       'domain name appears in HTML');
    like($result->{html}, qr/CNAME record not found/, 'error message appears in HTML');
    like($result->{html}, qr{admin/domains},          'retry link present in HTML');
    like($result->{text}, qr/dance-stars\.com/,       'domain name appears in text');
    like($result->{text}, qr/CNAME record not found/, 'error message appears in text');
    like($result->{text}, qr{admin/domains},          'retry link present in text');
};

done_testing();
