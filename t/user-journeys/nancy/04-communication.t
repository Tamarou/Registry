#!/usr/bin/env perl
# ABOUTME: Nancy user journey: communication -- receive messages, check unread count, mark messages as read
# ABOUTME: Tests the Message DAO send/receive/mark-read flow and HTTP message routes

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Fixtures;

use Registry::DAO::User;
use Registry::DAO::MagicLinkToken;
use Registry::DAO::Message;

my $tdb = Test::Registry::DB->new;
my $db  = $tdb->db;

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper( dao => sub { $db } );

# Create tenant
my $tenant = Test::Registry::Fixtures::create_tenant( $db, {
    name => 'Nancy Communication School',
    slug => 'nancy_comms',
} );

$db->schema( $tenant->slug );

# Create a program scope for messages
my $program = Test::Registry::Fixtures::create_project( $db, {
    name  => 'Music Academy',
    notes => 'Instrumental music program',
} );

# Create an admin who will send messages
my $admin = Registry::DAO::User->create( $db->db, {
    username  => 'nancy_comms_admin',
    name      => 'Admin Smith',
    email     => 'admin@music.example',
    user_type => 'admin',
} );

# Create Nancy as a parent recipient
my $nancy = Registry::DAO::User->create( $db->db, {
    username  => 'nancy.comms',
    name      => 'Nancy Comms',
    email     => 'nancy.comms@family.example',
    user_type => 'parent',
} );

subtest 'Nancy starts with no unread messages' => sub {
    my $count = Registry::DAO::Message->get_unread_count( $db->db, $nancy->id );
    is( $count, 0, 'No unread messages before any are sent' );
};

subtest 'Admin can send a message to Nancy' => sub {
    my $message = Registry::DAO::Message->send_message(
        $db->db,
        {
            sender_id    => $admin->id,
            subject      => 'Welcome to Music Academy',
            body         => 'We are excited to have your child join us this term.',
            message_type => 'announcement',
            scope        => 'program',
            scope_id     => $program->id,
        },
        [ $nancy->id ],
        send_now       => 1,
        recipient_type => 'parent',
    );

    ok( $message,                                     'Message sent successfully' );
    is( $message->subject, 'Welcome to Music Academy', 'Subject is correct' );
    ok( $message->sent_at,                            'Message has sent_at timestamp' );
};

subtest 'Nancy has one unread message after receiving it' => sub {
    my $count = Registry::DAO::Message->get_unread_count( $db->db, $nancy->id );
    is( $count, 1, 'Nancy has exactly one unread message' );
};

subtest 'Nancy can retrieve her messages' => sub {
    my $messages = Registry::DAO::Message->get_messages_for_parent( $db->db, $nancy->id );
    ok( scalar(@$messages) >= 1,          'At least one message found' );
    is( $messages->[0]->{subject}, 'Welcome to Music Academy', 'Message subject correct' );
};

subtest 'Nancy can mark a message as read via DAO' => sub {
    my $messages = Registry::DAO::Message->get_messages_for_parent( $db->db, $nancy->id );
    my $msg = $messages->[0];
    my $msg_id = $msg->{id};

    my $message_obj = Registry::DAO::Message->find( $db->db, { id => $msg_id } );
    ok( $message_obj, 'Message object retrieved' );

    # mark_as_read updates the read_at timestamp in message_recipients
    $message_obj->mark_as_read( $db->db, $nancy->id );

    # Unread count should drop to zero
    my $count = Registry::DAO::Message->get_unread_count( $db->db, $nancy->id );
    is( $count, 0, 'Unread count is 0 after marking read' );
};

subtest 'Admin can send a second message' => sub {
    my $message2 = Registry::DAO::Message->send_message(
        $db->db,
        {
            sender_id    => $admin->id,
            subject      => 'First Rehearsal Reminder',
            body         => 'Reminder: first rehearsal is on Monday.',
            message_type => 'update',
            scope        => 'program',
            scope_id     => $program->id,
        },
        [ $nancy->id ],
        send_now       => 1,
        recipient_type => 'parent',
    );

    ok( $message2, 'Second message sent' );

    my $count = Registry::DAO::Message->get_unread_count( $db->db, $nancy->id );
    is( $count, 1, 'Unread count is 1 after second message arrives' );
};

subtest 'Nancy authenticates via magic link' => sub {
    my ( $token_obj, $plaintext ) = Registry::DAO::MagicLinkToken->generate( $db->db, {
        user_id => $nancy->id,
        purpose => 'login',
    } );

    $t->get_ok("/auth/magic/$plaintext")
      ->status_is(200, 'Magic link verify page renders');

    $t->post_ok("/auth/magic/$plaintext/complete")
      ->status_is(302, 'Magic link complete redirects on success');
};

subtest 'GET /messages returns 200 for authenticated parent' => sub {
    $t->get_ok('/messages')
      ->status_is(200, 'Messages index returns 200');
};

subtest 'GET /messages/unread_count returns JSON for authenticated parent' => sub {
    $t->get_ok('/messages/unread_count')
      ->status_is(200, 'Unread count endpoint returns 200');
};

subtest 'POST /messages/:id/mark_read works for authenticated parent' => sub {
    my $messages = Registry::DAO::Message->get_messages_for_parent( $db->db, $nancy->id );
    my $msg_id = $messages->[0]->{id};

    $t->post_ok("/messages/$msg_id/mark_read")
      ->status_is(200, 'Mark read endpoint returns 200');
};

done_testing;
