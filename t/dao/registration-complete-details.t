#!/usr/bin/env perl
# ABOUTME: The confirmation page must name the child and the session that was just paid for.
# ABOUTME: It read keys no step writes, so every camper read "N/A" and every session was blank.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Mojo;
use Registry;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::WorkflowSteps::RegistrationComplete;
use Registry::DAO::User;
use Registry::DAO::Family;
use Registry::DAO::Session;

my $test_db     = Test::Registry::DB->new;
my $registry    = $test_db->db;
my $registry_db = $registry->db;

my $tenant = Test::Registry::Fixtures::create_tenant( $registry_db, {
    name => 'Clay and Kiln Studio', slug => 'complete_page',
} );
$registry_db->query( 'SELECT clone_schema(?)', 'complete_page' );
my $dao = Registry::DAO->new( url => $test_db->uri, schema => 'complete_page' );
my $db  = $dao->db;

my $parent = Registry::DAO::User->create( $db, {
    email => 'parent@complete.test', username => 'completeparent',
    name => 'Nancy Parent', user_type => 'parent',
} );

my $kylie = Registry::DAO::Family->add_child( $db, $parent->id, {
    child_name => 'Kylie', birth_date => '2016-03-15', grade => '3',
    medical_info => {}, emergency_contact => { name => 'N', phone => '555-0123' },
} );
my $rob = Registry::DAO::Family->add_child( $db, $parent->id, {
    child_name => 'Rob', birth_date => '2014-06-20', grade => '5',
    medical_info => {}, emergency_contact => { name => 'N', phone => '555-0123' },
} );

# Two sessions, so a page that renders one label for everyone is visibly wrong.
my $pottery = Registry::DAO::Session->create( $db, {
    name => 'Pottery Intensive', start_date => '2026-07-06', end_date => '2026-07-10',
    status => 'published', metadata => {},
} );
my $printmaking = Registry::DAO::Session->create( $db, {
    name => 'Printmaking Week', start_date => '2026-07-13', end_date => '2026-07-17',
    status => 'published', metadata => {},
} );

my $workflow = Registry::DAO::Workflow->create( $db, {
    name => 'Complete Page Workflow', slug => 'complete-page-workflow',
    description => 'Renders the confirmation page',
} );
Registry::DAO::WorkflowStep->create( $db, {
    workflow_id => $workflow->id, slug => 'complete',
    class => 'Registry::DAO::WorkflowSteps::RegistrationComplete',
    description => 'Registration Complete',
} );
$workflow->update( $db, { first_step => 'complete' }, { id => $workflow->id } );
$workflow = Registry::DAO::Workflow->find( $db, { id => $workflow->id } );

# Fetched the way the controller fetches it, so the class named in the workflow
# YAML has to actually load and dispatch -- not just exist on disk.
my $step = $workflow->first_step($db);
isa_ok $step, 'Registry::DAO::WorkflowSteps::RegistrationComplete';

# Exactly the shape MultiChildSessionSelection writes -- the page has to read
# the keys the workflow actually produces, which is the whole of this bug.
my $run = $workflow->new_run($db);
$run->update_data( $db, {
    children => [
        { id => $kylie->id, first_name => 'Kylie', last_name => '', grade => '3' },
        { id => $rob->id,   first_name => 'Rob',   last_name => '', grade => '5' },
    ],
    session_selections => {
        $kylie->id => $pottery->id,
        $rob->id   => $printmaking->id,
    },
} );

subtest 'the confirmation names each camper and the session they are in' => sub {
    my $data = $step->prepare_template_data( $db, $run );
    my $registrations = $data->{registrations};

    is ref $registrations, 'ARRAY', 'the page is given a list to render';
    is scalar $registrations->@*, 2, 'one entry per registered child';

    my %by_child = map { $_->{child_name} => $_ } $registrations->@*;

    is $by_child{Kylie}{grade}, '3', 'the grade comes from the run, not N/A';
    is $by_child{Kylie}{session}->name, 'Pottery Intensive', 'and her session is named';
    is $by_child{Kylie}{session}->start_date, '2026-07-06', 'with the dates she chose';
    is $by_child{Kylie}{session}->end_date,   '2026-07-10', 'both of them';

    # The sibling proves the page reads per-child selections rather than
    # labelling everyone with whatever the first child picked.
    is $by_child{Rob}{session}->name, 'Printmaking Week', 'the sibling gets his own session';
};

# A parent can finish a registration with one child seated and one waiting.
# Telling them both children are "joining us this summer" is the page saying a
# seat exists where none does -- and the waiting child, having no entry in
# session_selections, used to render with no session name at all.
subtest 'a child who is waiting is shown as waiting, not as enrolled' => sub {
    my $mixed = $workflow->new_run($db);
    $mixed->update_data( $db, {
        children => [
            { id => $kylie->id, first_name => 'Kylie', last_name => '', grade => '3' },
            { id => $rob->id,   first_name => 'Rob',   last_name => '', grade => '5' },
        ],
        session_selections => { $kylie->id => $pottery->id },
        waitlist_items     => [
            { child_id => $rob->id, session_id => $printmaking->id,
              location_id => undef },
        ],
    } );

    my $data = $step->prepare_template_data( $db, $mixed );
    my %by_child = map { $_->{child_name} => $_ } $data->{registrations}->@*;

    ok !$by_child{Kylie}{waiting}, 'the seated child is not marked waiting';
    ok $by_child{Rob}{waiting}, 'the waiting child is';

    # The session is still named. Which session they are waiting for is the
    # thing the parent needs to know -- a bare "on the waitlist" says nothing.
    is $by_child{Rob}{session}->name, 'Printmaking Week',
        'and the page can still say what they are waiting for';
};

subtest 'a run with nothing selected renders no campers rather than dying' => sub {
    my $empty = $workflow->new_run($db);
    $empty->update_data( $db, { children => [], session_selections => {} } );

    my $data = $step->prepare_template_data( $db, $empty );
    is ref $data->{registrations}, 'ARRAY', 'still a list';
    is scalar $data->{registrations}->@*, 0, 'just an empty one';
};

# #389: the page printed camp@example.com and (555) 123-4567 at a parent who had
# just paid and had a question, greeted them into "our summer camp program"
# whatever the tenant actually runs, and promised a packet nobody sends.
subtest 'the page is told whose programme this is and how to reach them' => sub {
    $registry_db->insert( 'registry.tenant_profiles', {
        tenant_id     => $tenant->id,
        billing_email => 'hello@clayandkiln.test',
        billing_phone => '555-0199',
    } );

    my $run = $workflow->new_run($db);
    $run->update_data( $db, {
        __tenant_slug      => 'complete_page',
        children           => [ { id => $kylie->id, first_name => 'Kylie', grade => '3' } ],
        session_selections => { $kylie->id => $pottery->id },
    } );

    my $org = $step->prepare_template_data( $db, $run )->{organization};

    is $org->{name},  'Clay and Kiln Studio',   'the tenant names itself';
    is $org->{email}, 'hello@clayandkiln.test', 'with the address it gave';
    is $org->{phone}, '555-0199',               'and the number';
};

subtest 'the rendered page carries none of the invented details' => sub {
    my $run = $workflow->new_run($db);
    $run->update_data( $db, {
        __tenant_slug      => 'complete_page',
        children           => [ { id => $kylie->id, first_name => 'Kylie', grade => '3' } ],
        session_selections => { $kylie->id => $pottery->id },
    } );

    my $t = Test::Registry::Mojo->new('Registry');
    $t->app->helper( dao => sub { $dao } );

    my $html = $t->app->build_controller->render_to_string(
        template => 'summer-camp-registration/complete',
        %{ $step->prepare_template_data( $db, $run ) },
    );

    unlike $html, qr/camp\@example\.com/, 'no invented email address';
    unlike $html, qr/555\) 123-4567/,      'no invented phone number';
    unlike $html, qr/information packet/i,  'no packet nobody sends';
    unlike $html, qr/this summer/i,         'and no season a February pottery class is not in';

    like $html, qr/Clay and Kiln Studio/,    'it names the organization';
    like $html, qr/hello\@clayandkiln\.test/, 'and how to reach them';
    like $html, qr/555-0199/,                 'both ways';
};

subtest 'a tenant with no contact details is not given invented ones' => sub {
    # The fix must not swap one fabrication for another: a tenant that never
    # filled in a contact address has to send the parent somewhere true.
    my $bare = Test::Registry::Fixtures::create_tenant( $registry_db, {
        name => 'Bare Studio', slug => 'bare_studio',
    } );

    my $run = $workflow->new_run($db);
    $run->update_data( $db, {
        __tenant_slug      => 'bare_studio',
        children           => [ { id => $kylie->id, first_name => 'Kylie', grade => '3' } ],
        session_selections => { $kylie->id => $pottery->id },
    } );

    my $data = $step->prepare_template_data( $db, $run );
    is $data->{organization}{name}, 'Bare Studio', 'the name is still known';
    ok !$data->{organization}{email}, 'and there is no address to print';

    my $t = Test::Registry::Mojo->new('Registry');
    $t->app->helper( dao => sub { $dao } );
    my $html = $t->app->build_controller->render_to_string(
        template => 'summer-camp-registration/complete',
        %$data,
    );

    unlike $html, qr/camp\@example\.com/, 'still nothing invented';
    like $html, qr/program organizer/i,
        'the parent is pointed at a person rather than a fabricated address';
};

subtest 'the primary user is the fallback when no billing address was given' => sub {
    my $quiet = Test::Registry::Fixtures::create_tenant( $registry_db, {
        name => 'Quiet Studio', slug => 'quiet_studio',
    } );
    my $owner = Registry::DAO::User->create( $registry_db, {
        email => 'owner@quiet.test', username => 'quietowner',
        name => 'Quiet Owner', user_type => 'admin',
    } );
    $quiet->add_user( $registry_db, $owner, 1 );

    my $run = $workflow->new_run($db);
    $run->update_data( $db, {
        __tenant_slug      => 'quiet_studio',
        children           => [ { id => $kylie->id, first_name => 'Kylie', grade => '3' } ],
        session_selections => { $kylie->id => $pottery->id },
    } );

    my $org = $step->prepare_template_data( $db, $run )->{organization};
    is $org->{email}, 'owner@quiet.test',
        "the owner's own address, rather than no way to reach anyone";
};

done_testing;
