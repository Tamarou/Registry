#!/usr/bin/env perl
# ABOUTME: A person invited into a tenant is actually sent their invitation, with who and what.
# ABOUTME: Sent by an admin from /admin/people -- never by the anonymous signup form (#438).
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;

# Without this the happy-path send reaches a real SMTP transport and buries the
# run in connection backtraces.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }
use Registry::DAO::Notification;
use Registry::DAO::Tenant;
use Registry::Email::Template;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

# The invite template names the inviter and the role. Nothing supplied either,
# so an invitation read "  has invited you to join X as a  ".
subtest 'the invite email names who invited you and to what' => sub {
    my $rendered = Registry::Email::Template->render( 'magic_link_invite',
        tenant_name    => 'Pottery Studio',
        inviter_name   => 'Jordan Owner',
        role           => 'admin',
        magic_link_url => 'https://example.test/auth/magic/tok',
    );

    like $rendered->{html}, qr/Jordan Owner/, 'the inviter is named';
    like $rendered->{html}, qr/admin/,        'and the role offered';
    like $rendered->{html}, qr/Pottery Studio/, 'and the organisation';
    like $rendered->{text}, qr/Jordan Owner/, 'in the text part too';
};

# The notification layer is what carries those to the template. It passed the
# tenant and the URL and dropped the other two.
subtest 'the notification carries the inviter and role to the template' => sub {
    my $user = $dao->create( User => {
        username => 'invitee_' . time, user_type => 'staff',
        email => 'invitee_' . time . '@test.local', name => 'Morgan Manager',
    } );

    my $notification = Registry::DAO::Notification->create( $db, {
        user_id  => $user->id,
        type     => 'magic_link_invite',
        channel  => 'email',
        subject  => 'You have been invited',
        message  => 'Invitation',
        metadata => {
            tenant_name    => 'Pottery Studio',
            inviter_name   => 'Jordan Owner',
            role           => 'admin',
            magic_link_url => 'https://example.test/auth/magic/tok',
        },
    } );

    my %vars = $notification->_template_vars( { email => 'x@test.local', name => 'Morgan' } );

    is $vars{inviter_name}, 'Jordan Owner', 'the inviter reaches the template';
    is $vars{role},         'admin',        'and the role';
    is $vars{tenant_name},  'Pottery Studio', 'alongside what already worked';
    is $vars{magic_link_url}, 'https://example.test/auth/magic/tok', 'and the link';
};

# The invitation is sent after Tenant->provision has already committed, so a
# throw from any part of it -- minting the token, recording the notification,
# handing it to the transport -- used to abort a step whose tenant was already
# real. The guard has to cover the whole invitation, not just the send.
subtest 'a tenant that cannot be invited into is still a provisioned tenant' => sub {
    local $ENV{REGISTRY_BASE_DOMAINS} = 'tinyartempire.com';

    my $suffix = time . $$;
    my $admin  = $dao->create( User => {
        username => "owner_$suffix", user_type => 'admin',
        email => "owner_$suffix\@test.local", name => 'Jordan Owner',
    } );
    my $tenant = Registry::DAO::Tenant->provision( $db, {
        name  => "Invite Guard $suffix",
        slug  => "invite_guard_$suffix",
        users => [$admin],
    } );

    my $tenant_dao   = $tenant->dao($db);
    my $tenant_admin = $tenant_dao->find( User => { username => "owner_$suffix" } );

    # Happy path first, so the failure case below cannot pass by doing nothing.
    # Tenant->invite_user, not a signup step: signup must not send invitations at
    # all -- it is an anonymous form and the addresses on it are whatever the
    # caller typed (#438) -- so the sender moved to where an authenticated admin
    # can reach it.
    ok $tenant->invite_user( $db, $tenant_admin, 'Jordan Owner' ),
        'the invitation reports success';

    my $sent = $tenant_dao->db->query(
        'SELECT metadata FROM notifications WHERE user_id = ? AND type = ?',
        $tenant_admin->id, 'magic_link_invite' )->expand->hashes;
    is scalar($sent->@*), 1, 'the invitation was recorded in the tenant schema';
    like $sent->[0]{metadata}{magic_link_url},
        qr{\Qhttps://invite_guard_$suffix.tinyartempire.com\E},
        'and its link points at the tenant, not the apex';

    # A user created after provisioning was never copied into <tenant>.users, so
    # the FK on the invitation rows rejects its id. That is a real throw from
    # inside the guard, before the send -- not a simulated one. (Passing $admin
    # would not do it: provision copies him into the tenant schema id and all.)
    my $stranger = $dao->create( User => {
        username => "stranger_$suffix", user_type => 'staff',
        email => "stranger_$suffix\@test.local", name => 'Not In This Tenant',
    } );
    my @warnings;
    my $ok = do {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        eval { !$tenant->invite_user( $db, $stranger, 'Jordan Owner' ) };
    };
    ok $ok, 'an undeliverable invitation returns false rather than throwing';
    like "@warnings", qr/\Qstranger_$suffix\E\@test\.local/,
        'and it says out loud who was not reached';

    ok $db->query( 'SELECT 1 FROM registry.tenants WHERE slug = ?',
        "invite_guard_$suffix" )->rows, 'and the tenant it was for is still there';
};

done_testing;
