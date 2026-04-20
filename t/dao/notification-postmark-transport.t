#!/usr/bin/env perl
# ABOUTME: Verifies Registry::DAO::Notification builds a Postmark SMTP
# ABOUTME: transport when POSTMARK_SERVER_TOKEN is set.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;

# Must require before inspecting _postmark_transport.
use_ok 'Registry::DAO::Notification';

subtest 'no token -> no custom transport' => sub {
    local $ENV{EMAIL_SENDER_TRANSPORT};
    local $ENV{POSTMARK_SERVER_TOKEN};
    delete $ENV{EMAIL_SENDER_TRANSPORT};
    delete $ENV{POSTMARK_SERVER_TOKEN};
    my $transport = Registry::DAO::Notification::_postmark_transport();
    ok(!defined $transport, 'returns undef without token');
};

subtest 'token -> SMTP transport pointed at Postmark' => sub {
    # CI sets EMAIL_SENDER_TRANSPORT=Test at the workflow level; clear
    # it here so we exercise the production branch.
    local $ENV{EMAIL_SENDER_TRANSPORT};
    delete $ENV{EMAIL_SENDER_TRANSPORT};
    local $ENV{POSTMARK_SERVER_TOKEN} = 'test-token-xyz';
    my $transport = Registry::DAO::Notification::_postmark_transport();

    ok(defined $transport, 'returns a transport');
    isa_ok($transport, 'Email::Sender::Transport::SMTP');
    is($transport->host, 'smtp.postmarkapp.com', 'points at Postmark');
    is($transport->port, 587,                    'uses submission port');
    is($transport->sasl_username, 'test-token-xyz', 'SASL user is the token');
    is($transport->sasl_password, 'test-token-xyz', 'SASL pass is the token');
};

subtest 'Test transport env var takes precedence' => sub {
    # When tests set EMAIL_SENDER_TRANSPORT=Test, _postmark_transport
    # should return undef so the test transport is picked up naturally
    # by Email::Sender::Simple's auto-discovery. This preserves the
    # BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' } pattern used in
    # other tests.
    local $ENV{POSTMARK_SERVER_TOKEN}   = 'ignored';
    local $ENV{EMAIL_SENDER_TRANSPORT}  = 'Test';
    my $transport = Registry::DAO::Notification::_postmark_transport();
    ok(!defined $transport, 'returns undef when test transport requested');
};

done_testing();
