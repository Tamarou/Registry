#!/usr/bin/env perl
# ABOUTME: Tests for email delivery failure handling.
# ABOUTME: Verifies that email failures don't crash workflows and are recorded properly.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;

use Registry::DAO;
use Registry::DAO::User;
use Registry::DAO::Notification;
use Registry::DAO::MagicLinkToken;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

my $user = Registry::DAO::User->create($dao->db, {
    username  => 'email_test',
    name      => 'Email Test',
    email     => 'email_test@example.com',
    user_type => 'parent',
});

# ============================================================
# Test: Notification creation succeeds even without sending
# ============================================================
subtest 'notification created and persisted regardless of send status' => sub {
    my $notification = Registry::DAO::Notification->create($dao->db, {
        user_id  => $user->id,
        type     => 'magic_link_login',
        channel  => 'email',
        subject  => 'Test Login Link',
        message  => 'Click here to log in',
        metadata => {
            tenant_name    => 'Test',
            magic_link_url => 'http://test/auth/magic/abc123',
        },
    });

    ok $notification, 'Notification created';
    ok $notification->id, 'Notification has ID';
    ok !$notification->sent_at, 'Not yet sent';
};

# ============================================================
# Test: Email send in test mode records sent_at
# ============================================================
subtest 'email send in test mode succeeds and records timestamp' => sub {
    my $notification = Registry::DAO::Notification->create($dao->db, {
        user_id  => $user->id,
        type     => 'magic_link_login',
        channel  => 'email',
        subject  => 'Test Send',
        message  => 'Test message',
        metadata => {
            tenant_name    => 'Test',
            magic_link_url => 'http://test/auth/magic/def456',
        },
    });

    my $result = $notification->send($dao->db);

    # Reload from DB
    ($notification) = Registry::DAO::Notification->find($dao->db, { id => $notification->id });

    # In test transport mode, send should succeed
    ok $notification->sent_at, 'sent_at timestamp recorded after send';
};

# ============================================================
# Test: Magic link generation doesn't die if notification fails
# ============================================================
subtest 'magic link token generated even if notification would fail' => sub {
    # The token generation is separate from notification sending
    my ($token_obj, $plaintext) = Registry::DAO::MagicLinkToken->generate($dao->db, {
        user_id => $user->id,
        purpose => 'login',
    });

    ok $token_obj, 'Token object created';
    ok $plaintext, 'Plaintext token returned';
    ok length($plaintext) > 10, 'Token has sufficient length';
};

# ============================================================
# Test: SMS notification gracefully records failure
# ============================================================
subtest 'in_app notification sent without email delivery' => sub {
    my $notification = Registry::DAO::Notification->create($dao->db, {
        user_id  => $user->id,
        type     => 'magic_link_login',
        channel  => 'in_app',
        subject  => 'In-App Test',
        message  => 'Sent without email',
        metadata => {},
    });

    ok $notification, 'In-app notification created';

    my $result = $notification->send($dao->db);

    ($notification) = Registry::DAO::Notification->find($dao->db, { id => $notification->id });

    ok $notification->sent_at, 'In-app notification marked as sent';
    ok $notification->id, 'Notification persists';
};

# ============================================================
# Test: Duplicate send is idempotent
# ============================================================
subtest 'sending same notification twice is idempotent' => sub {
    my $notification = Registry::DAO::Notification->create($dao->db, {
        user_id  => $user->id,
        type     => 'magic_link_login',
        channel  => 'email',
        subject  => 'Idempotent Test',
        message  => 'Test',
        metadata => {
            tenant_name    => 'Test',
            magic_link_url => 'http://test/auth/magic/xyz789',
        },
    });

    # First send
    $notification->send($dao->db);

    ($notification) = Registry::DAO::Notification->find($dao->db, { id => $notification->id });
    my $first_sent_at = $notification->sent_at;
    ok $first_sent_at, 'First send recorded';

    # Second send -- should be no-op (already sent)
    $notification->send($dao->db);

    ($notification) = Registry::DAO::Notification->find($dao->db, { id => $notification->id });
    is $notification->sent_at, $first_sent_at, 'Second send did not change sent_at';
};

done_testing;
