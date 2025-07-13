use 5.40.2;
use lib          qw(lib t/lib);
use experimental qw(defer builtin);

use Test::More;
defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Mojo::Home;
use YAML::XS;

# Create a test database
my $dao = Registry::DAO->new( url => Test::Registry::DB->new_test_db() );
my $db  = $dao->db;

# TODO: move these to t/lib/Test/Registry.pm
my @files =
  Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;
for my $file (@files) {
    next if Load( $file->slurp )->{draft};
    Workflow->from_yaml( $dao, $file->slurp );
}

Registry::DAO::Template->import_from_file( $dao, $_ )
  for Mojo::Home->new->child('templates')->list_tree->grep(qr/\.html\.ep$/)
  ->each;

# Create a test tenant directly for testing summer camp functionality
my $tenant = Test::Registry::Fixtures::create_tenant($dao, {
    name => 'Super Awesome Cool Pottery',
    slug => 'super_awesome_cool_pottery'
});
ok $tenant, 'Tenant created successfully';

# Create the tenant schema with all required tables
$db->query('SELECT clone_schema(dest_schema => ?)', $tenant->slug);

# Connect to the tenant's schema
my $tenant_dao = $dao->connect_schema( $tenant->slug );
my $tenant_db  = $tenant_dao->db;

# Create users directly in tenant schema
my $admin_user = Test::Registry::Fixtures::create_user($tenant_dao, {
    username => 'pottery_admin',
    password => 'password123',
    user_type => 'admin'
});
ok $admin_user, 'Admin user created in tenant schema';

my $main_teacher = Test::Registry::Fixtures::create_user($tenant_dao, {
    username => 'pottery_teacher',
    password => 'password123',
    user_type => 'staff'
});
ok $main_teacher, 'Teacher user created in tenant schema';

# Create additional test users in tenant schema
my $assistant_teacher = Test::Registry::Fixtures::create_user($tenant_dao, {
    username => 'pottery_assistant',
    password => 'password123',
    user_type => 'staff'
});
ok $assistant_teacher, 'Created assistant teacher user in tenant schema';

my $student = Test::Registry::Fixtures::create_user($tenant_dao, {
    username => 'pottery_student',
    password => 'password123',
    user_type => 'student'
});
ok $student, 'Created student user in tenant schema';

# Create test location with summer camp fields in tenant schema
my $location = Test::Registry::Fixtures::create_location($tenant_dao, {
    name         => 'Pottery Studio',
    address_info => {
        address_street => '456 Clay Lane',
        address_city   => 'Ceramicville',
        address_state  => 'NY',
        address_zip    => '12345',
    },
    capacity     => 15,
    contact_info =>
      { phone => '555-987-6543', email => 'pottery@example.com' },
    facilities => [ 'kiln', 'pottery wheels', 'glazing station' ],
    latitude   => 40.7128,
    longitude  => -74.0060
});

ok $location isa 'Registry::DAO::Location', 'Created location in tenant schema';
is $location->name, 'Pottery Studio', 'Location name set correctly';
is $location->address_info->{address_city}, 'Ceramicville',
  'Location address_city set correctly';
is $location->capacity, 15, 'Location capacity set correctly';

# Create a test project in tenant schema
my $project = Test::Registry::Fixtures::create_project($tenant_dao, {
    name => 'Summer Pottery Camp Curriculum'
});
ok $project, 'Created project in tenant schema';

# Create a camp session in tenant schema
my $camp_session = Test::Registry::Fixtures::create_session($tenant_dao, {
    name       => 'Summer Pottery Camp 2025',
    slug       => 'summer-pottery-camp-2025',
    start_date => '2025-07-10',
    end_date   => '2025-07-15',
    status     => 'draft'
});

ok $camp_session, 'Created camp session in tenant schema';
is $camp_session->name, 'Summer Pottery Camp 2025',
  'Session name set correctly';
is $camp_session->start_date, '2025-07-10', 'Session start_date set correctly';
is $camp_session->end_date,   '2025-07-15', 'Session end_date set correctly';
is $camp_session->status,     'draft',      'Session status set to draft';

# Create camp day events in tenant schema
my @camp_events;
for my $day ( 0 .. 4 ) {
    my $date = sprintf( "2025-07-%d", 10 + $day );
    push @camp_events, Test::Registry::Fixtures::create_event($tenant_dao, {
        time        => "$date 10:00:00",
        duration    => 360,                 # 6 hours in minutes
        location_id => $location->id,
        project_id  => $project->id,
        teacher_id  => $main_teacher->id,
        min_age     => 10,
        max_age     => 16,
        capacity    => 15
    });
}

is scalar(@camp_events),      5,  'Created 5 camp day events in tenant schema';
is $camp_events[0]->min_age,  10, 'Event min_age set correctly';
is $camp_events[0]->max_age,  16, 'Event max_age set correctly';
is $camp_events[0]->capacity, 15, 'Event capacity set correctly';

# Add teachers to the session in tenant schema
$camp_session->add_teachers( $tenant_db, $main_teacher->id,
    $assistant_teacher->id );

# Verify teachers were added to sessions
my @teachers = $camp_session->teachers($tenant_db);
is scalar(@teachers), 2, 'Session has 2 teachers in tenant schema';

# Add events to the session in tenant schema
$camp_session->add_events( $tenant_db, map { $_->id } @camp_events );

# Verify the events were added to the session
my @session_events = $camp_session->events($tenant_db);
is scalar(@session_events), 5, 'Session has 5 events in tenant schema';

# Verify event belongs to session
my @event_sessions = $camp_events[0]->sessions($tenant_db);
is scalar(@event_sessions), 1, 'Event belongs to 1 session in tenant schema';
is $event_sessions[0]->id, $camp_session->id,
  'Event belongs to correct session in tenant schema';

# Create pricing for the camp session in tenant schema
my $pricing = Test::Registry::Fixtures::create_pricing($tenant_dao, {
    session_id             => $camp_session->id,
    plan_name              => 'Standard Camp Pricing',
    plan_type              => 'standard',
    amount                 => 349.99,
    currency               => 'USD',
    requirements           => {
        early_bird_cutoff_date => '2025-05-15',
        sibling_discount       => 15.00
    }
});

ok $pricing, 'Created pricing in tenant schema';
is $pricing->amount, 349.99, 'Pricing amount set correctly';
is $pricing->plan_name, 'Standard Camp Pricing',
  'Pricing plan_name set correctly';
is $pricing->plan_type, 'standard',
  'Pricing plan_type set correctly';
is $pricing->requirements->{sibling_discount}, 15.00,
  'Pricing sibling_discount set correctly in requirements';

# Test pricing helper methods
my $calculated_price = $pricing->calculate_price();
is $calculated_price, 349.99,
  'calculate_price returns correct amount in tenant schema';

# Test session pricing relationship - need to check if this method exists
# Skip this test for now as it depends on Session having a pricing method

# Test pricing formatted output
like $pricing->formatted_price, qr/\$\d+\.\d{2}/,
  'formatted_price returns currency string in tenant schema';

# Test session status transitions
$camp_session->publish($tenant_db);
is $camp_session->status, 'published',
  'Session published successfully in tenant schema';
ok $camp_session->is_published,
  'is_published returns true after publishing in tenant schema';

# Create enrollment for the session in tenant schema
my $enrollment = Test::Registry::Fixtures::create_enrollment($tenant_dao, {
    session_id => $camp_session->id,
    student_id => $student->id,
    status     => 'active'
});

ok $enrollment, 'Created enrollment in tenant schema';
is $enrollment->session_id, $camp_session->id,
  'Enrollment session_id set correctly in tenant schema';
is $enrollment->student_id, $student->id,
  'Enrollment student_id set correctly in tenant schema';
is $enrollment->status, 'active',
  'Enrollment status set correctly in tenant schema';
ok $enrollment->is_active,
  'is_active returns true for active enrollments in tenant schema';

# Test enrollment relationships
my $enrollment_session = $enrollment->session($tenant_db);
ok $enrollment_session, 'Retrieved session from enrollment in tenant schema';
is $enrollment_session->id, $camp_session->id,
  'Retrieved correct session in tenant schema';

my $enrollment_student = $enrollment->student($tenant_db);
ok $enrollment_student, 'Retrieved student from enrollment in tenant schema';
is $enrollment_student->id, $student->id,
  'Retrieved correct student in tenant schema';

# Test session enrollments relationship
my @session_enrollments = $camp_session->enrollments($tenant_db);
is scalar(@session_enrollments), 1, 'Session has 1 enrollment in tenant schema';
is $session_enrollments[0]->id, $enrollment->id,
  'Retrieved correct enrollment in tenant schema';

# Test enrollment status transitions
$enrollment->waitlist($tenant_db);
is $enrollment->status, 'waitlisted',
  'Enrollment waitlisted successfully in tenant schema';
ok $enrollment->is_waitlisted,
  'is_waitlisted returns true after waitlisting in tenant schema';

$enrollment->activate($tenant_db);
is $enrollment->status, 'active',
  'Enrollment activated successfully in tenant schema';

# Test closing the session
$camp_session->close($tenant_db);
is $camp_session->status, 'closed',
  'Session closed successfully in tenant schema';
ok $camp_session->is_closed,
  'is_closed returns true after closing in tenant schema';

# Test that Super Awesome Cool Pottery's data is isolated
{
    # Create another tenant directly for isolation testing
    my $another_tenant = Test::Registry::Fixtures::create_tenant($dao, {
        name => 'Another Tenant',
        slug => 'another_tenant'
    });

    # Create the tenant schema with all required tables
    $db->query('SELECT clone_schema(dest_schema => ?)', $another_tenant->slug);

    my $another_tenant_dao = $dao->connect_schema( $another_tenant->slug );
    my @another_tenant_camps =
      $another_tenant_dao->find('Registry::DAO::Session');
    is scalar(@another_tenant_camps), 0,
      'No camp sessions found in another tenant schema';
}
