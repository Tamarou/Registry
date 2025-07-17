use 5.40.2;
use lib          qw(lib t/lib);
use experimental qw(defer try);
use Test::More import => [qw( done_testing is ok like is_deeply )];
defer { done_testing };

use Test::Registry::DB;
use Test::Registry::Fixtures;

# Setup test database
my $t  = Test::Registry::DB->new;
my $db = $t->db;

# Create a test tenant (in registry schema)
my $tenant = Test::Registry::Fixtures::create_tenant($db, {
    name => 'Test Organization',
    slug => 'test_org',
});

# Create the tenant schema with all required tables
$db->db->query('SELECT clone_schema(dest_schema => ?)', $tenant->slug);

# Create test users (in registry schema)
my $admin = Test::Registry::Fixtures::create_user($db, {
    username => 'admin',
    password => 'password123',
    user_type => 'admin',
});

my $staff = Test::Registry::Fixtures::create_user($db, {
    username => 'staff',
    password => 'password123',
    user_type => 'staff',
});

my $parent1 = Test::Registry::Fixtures::create_user($db, {
    username => 'parent1',
    password => 'password123',
    user_type => 'parent',
});

my $parent2 = Test::Registry::Fixtures::create_user($db, {
    username => 'parent2',
    password => 'password123',
    user_type => 'parent',
});

# Copy users to tenant schema
$db->db->query('SELECT copy_user(dest_schema => ?, user_id => ?)', $tenant->slug, $admin->id);
$db->db->query('SELECT copy_user(dest_schema => ?, user_id => ?)', $tenant->slug, $staff->id);
$db->db->query('SELECT copy_user(dest_schema => ?, user_id => ?)', $tenant->slug, $parent1->id);
$db->db->query('SELECT copy_user(dest_schema => ?, user_id => ?)', $tenant->slug, $parent2->id);

# Switch to tenant schema for operations
$db = $db->schema($tenant->slug);

# Use DAO directly for operations
use Registry::DAO::Message;

{    # Basic message creation
    my $message = Registry::DAO::Message->create( $db, {
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
    
    my $message = Registry::DAO::Message->send_message($db, {
        sender_id => $staff->id,
        subject => 'Immediate Message',
        body => 'This message is sent immediately',
        message_type => 'update',
        scope => 'tenant-wide'
    }, $recipients, send_now => 1);
    
    ok $message, 'Message sent successfully';
    ok $message->is_sent, 'Message marked as sent';
    
    # Check recipients were added
    my $recipient_count = $db->db->select('message_recipients', 
        [\'count(*)'], 
        { message_id => $message->id }
    )->array->[0];
    
    is $recipient_count, 2, 'Correct number of recipients added';
}

{    # Recipients by scope
    my $tenant_recipients = Registry::DAO::Message->get_recipients_for_scope(
        $db, 'tenant-wide'
    );
    
    ok @$tenant_recipients >= 2, 'Found tenant-wide recipients';
    
    # Test invalid scope
    my $invalid_recipients = Registry::DAO::Message->get_recipients_for_scope(
        $db, 'invalid-scope'
    );
    
    is_deeply $invalid_recipients, [], 'Empty array for invalid scope';
}

{    # Parent message retrieval
    # Create a message for testing
    my $message = Registry::DAO::Message->send_message($db, {
        sender_id => $staff->id,
        subject => 'Parent Test Message',
        body => 'Message for parent retrieval test',
        message_type => 'announcement',
        scope => 'tenant-wide'
    }, [$parent1->id], send_now => 1);
    
    # Get messages for parent
    my $parent_messages = Registry::DAO::Message->get_messages_for_parent(
        $db, $parent1->id
    );
    
    ok @$parent_messages >= 1, 'Parent has messages';
    
    my $found_message = (grep { $_->{id} eq $message->id } @$parent_messages)[0];
    ok $found_message, 'Found the test message';
    is $found_message->{subject}, 'Parent Test Message', 'Message subject correct';
}

{    # Read tracking
    my $message = Registry::DAO::Message->send_message($db, {
        sender_id => $staff->id,
        subject => 'Read Tracking Test',
        body => 'Testing read tracking functionality',
        message_type => 'update',
        scope => 'tenant-wide'
    }, [$parent1->id], send_now => 1);
    
    # Check initial unread count
    my $initial_unread = Registry::DAO::Message->get_unread_count($db, $parent1->id);
    ok $initial_unread >= 1, 'Has unread messages';
    
    # Mark as read
    $message->mark_as_read($db, $parent1->id);
    
    # Check read status
    my $recipient = $db->db->select('message_recipients',
        ['read_at'],
        { message_id => $message->id, recipient_id => $parent1->id }
    )->hash;
    
    ok $recipient->{read_at}, 'Message marked as read';
}

{    # Helper methods
    my $emergency = $db->create( Message => {
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