use 5.40.2;
use lib          qw(lib t/lib);
use experimental qw(defer try);
use Test::More import => [qw( done_testing is ok like is_deeply )];
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;
my $dao = Registry::DAO->new( url => Test::Registry::DB->new_test_db() );

# Create test users
my $admin = $dao->create( User => {
    email => 'admin@test.com',
    name => 'Test Admin',
    role => 'admin'
});

my $staff = $dao->create( User => {
    email => 'staff@test.com', 
    name => 'Test Staff',
    role => 'staff'
});

my $parent1 = $dao->create( User => {
    email => 'parent1@test.com',
    name => 'Test Parent 1', 
    role => 'parent'
});

my $parent2 = $dao->create( User => {
    email => 'parent2@test.com',
    name => 'Test Parent 2',
    role => 'parent'
});

{    # Basic message creation
    my $message = $dao->create( Message => {
        sender_id => $admin->id,
        subject => 'Test Message',
        body => 'This is a test message',
        message_type => 'announcement',
        scope => 'tenant-wide'
    });
    
    ok $message, 'Message created successfully';
    is $message->subject, 'Test Message', 'Subject set correctly';
    is $message->message_type, 'announcement', 'Message type set correctly';
    is $message->scope, 'tenant-wide', 'Scope set correctly';
}

{    # Message sending with recipients
    my $recipients = [$parent1->id, $parent2->id];
    
    my $message = Registry::DAO::Message->send_message($dao->db, {
        sender_id => $staff->id,
        subject => 'Immediate Message',
        body => 'This message is sent immediately',
        message_type => 'update',
        scope => 'tenant-wide'
    }, $recipients, send_now => 1);
    
    ok $message, 'Message sent successfully';
    ok $message->is_sent, 'Message marked as sent';
    
    # Check recipients were added
    my $recipient_count = $dao->db->select('message_recipients', 
        [\'count(*)'], 
        { message_id => $message->id }
    )->array->[0];
    
    is $recipient_count, 2, 'Correct number of recipients added';
}

{    # Recipients by scope
    my $tenant_recipients = Registry::DAO::Message->get_recipients_for_scope(
        $dao->db, 'tenant-wide'
    );
    
    ok @$tenant_recipients >= 2, 'Found tenant-wide recipients';
    
    # Test invalid scope
    my $invalid_recipients = Registry::DAO::Message->get_recipients_for_scope(
        $dao->db, 'invalid-scope'
    );
    
    is_deeply $invalid_recipients, [], 'Empty array for invalid scope';
}

{    # Parent message retrieval
    # Create a message for testing
    my $message = Registry::DAO::Message->send_message($dao->db, {
        sender_id => $staff->id,
        subject => 'Parent Test Message',
        body => 'Message for parent retrieval test',
        message_type => 'announcement',
        scope => 'tenant-wide'
    }, [$parent1->id], send_now => 1);
    
    # Get messages for parent
    my $parent_messages = Registry::DAO::Message->get_messages_for_parent(
        $dao->db, $parent1->id
    );
    
    ok @$parent_messages >= 1, 'Parent has messages';
    
    my $found_message = (grep { $_->{id} eq $message->id } @$parent_messages)[0];
    ok $found_message, 'Found the test message';
    is $found_message->{subject}, 'Parent Test Message', 'Message subject correct';
}

{    # Read tracking
    my $message = Registry::DAO::Message->send_message($dao->db, {
        sender_id => $staff->id,
        subject => 'Read Tracking Test',
        body => 'Testing read tracking functionality',
        message_type => 'update',
        scope => 'tenant-wide'
    }, [$parent1->id], send_now => 1);
    
    # Check initial unread count
    my $initial_unread = Registry::DAO::Message->get_unread_count($dao->db, $parent1->id);
    ok $initial_unread >= 1, 'Has unread messages';
    
    # Mark as read
    $message->mark_as_read($dao->db, $parent1->id);
    
    # Check read status
    my $recipient = $dao->db->select('message_recipients',
        ['read_at'],
        { message_id => $message->id, recipient_id => $parent1->id }
    )->hash;
    
    ok $recipient->{read_at}, 'Message marked as read';
}

{    # Helper methods
    my $emergency = $dao->create( Message => {
        sender_id => $admin->id,
        subject => 'Emergency Test',
        body => 'Emergency message',
        message_type => 'emergency',
        scope => 'tenant-wide'
    });
    
    ok $emergency->is_emergency, 'Emergency message identified correctly';
    ok !$emergency->is_announcement, 'Not an announcement';
    ok !$emergency->is_update, 'Not an update';
    
    # Test scope description
    is $emergency->scope_description, 'All families', 'Tenant-wide description correct';
}