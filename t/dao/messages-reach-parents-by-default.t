# ABOUTME: Tests MVP §7 -- announcements, updates and emergencies reach a parent who set no preferences.
# ABOUTME: wants_notification defaulted every message type to off, so none were ever delivered.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::Message;
use Registry::DAO::UserPreference;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $admin = $dao->create(User => {
    username => 'msg_admin', name => 'Studio Admin', user_type => 'admin',
    email => 'msg_admin@test.local',
});

# A parent exactly as registration leaves them: no preferences of any kind,
# because nothing in the product asks for any.
my $parent = $dao->create(User => {
    username => 'msg_parent', name => 'Message Parent', user_type => 'parent',
    email => 'msg_parent@test.local',
});

sub notifications_of ( $user, $type ) {
    return $db->select('notifications', '*',
        { user_id => $user->id, type => $type } )->hashes;
}

subtest 'a parent who has set nothing still wants to hear from the studio' => sub {
    # The defaults only ever covered attendance. Every message type fell through
    # to `// 0`, so this returned false for all of them -- including emergencies.
    for my $type (qw( message_emergency message_announcement message_update )) {
        for my $channel (qw( email in_app )) {
            ok Registry::DAO::UserPreference->wants_notification(
                    $db, $parent->id, $type, $channel ),
                "$type over $channel is on by default";
        }
    }
};

subtest 'an emergency message reaches the parent' => sub {
    Registry::DAO::Message->send_message(
        $db,
        {
            sender_id    => $admin->id,
            subject      => 'Class cancelled - burst pipe',
            body         => 'Today\'s class is cancelled. Please collect your child.',
            message_type => 'emergency',
            scope        => 'tenant-wide',
        },
        [ $parent->id ],
        send_now => 1,
    );

    my $rows = notifications_of( $parent, 'message_emergency' );
    my %by_channel = map { $_->{channel} => $_ } @$rows;

    ok $by_channel{email}, 'an email notification was queued';
    ok $by_channel{in_app}, 'and an in-app one';
    is $by_channel{email}{subject}, 'Class cancelled - burst pipe',
        'carrying the subject the studio wrote';
    like $by_channel{email}{message}, qr/collect your child/,
        'and the body';
};

subtest 'an announcement reaches the parent too' => sub {
    Registry::DAO::Message->send_message(
        $db,
        {
            sender_id    => $admin->id,
            subject      => 'Term dates for spring',
            body         => 'Spring term runs from March.',
            message_type => 'announcement',
            scope        => 'tenant-wide',
        },
        [ $parent->id ],
        send_now => 1,
    );

    my $rows = notifications_of( $parent, 'message_announcement' );
    ok scalar @$rows >= 1, 'the announcement was delivered';
};

subtest 'a parent who opts out of announcements still gets emergencies' => sub {
    my $opted_out = $dao->create(User => {
        username => 'quiet_parent', name => 'Quiet Parent', user_type => 'parent',
        email => 'quiet@test.local',
    });

    Registry::DAO::UserPreference->set_preference(
        $db, $opted_out->id, 'message_announcement', 'email', 0 );
    Registry::DAO::UserPreference->set_preference(
        $db, $opted_out->id, 'message_announcement', 'in_app', 0 );

    Registry::DAO::Message->send_message(
        $db,
        {
            sender_id    => $admin->id,
            subject      => 'Bake sale on Friday',
            body         => 'Bring cakes.',
            message_type => 'announcement',
            scope        => 'tenant-wide',
        },
        [ $opted_out->id ],
        send_now => 1,
    );
    is scalar @{ notifications_of( $opted_out, 'message_announcement' ) }, 0,
        'the announcement respects the opt-out';

    Registry::DAO::Message->send_message(
        $db,
        {
            sender_id    => $admin->id,
            subject      => 'Evacuation - collect your child',
            body         => 'Please come now.',
            message_type => 'emergency',
            scope        => 'tenant-wide',
        },
        [ $opted_out->id ],
        send_now => 1,
    );
    ok scalar @{ notifications_of( $opted_out, 'message_emergency' ) } >= 1,
        'but the emergency still arrives -- opting out of a bake sale is not '
      . 'opting out of an evacuation';
};

done_testing;
