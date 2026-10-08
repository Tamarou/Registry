# ABOUTME: A session's capacity, waitlist and price can be changed after it is generated.
# ABOUTME: All three were fixed at generation, and the only session route was the publish toggle.
#
# #419. Morgan sets capacity, pricing and the waitlist toggle on
# program-location-assignment, GenerateEvents writes them onto the session it
# creates, and after that nothing could change any of them -- the room changed,
# demand was misjudged, the override was wrong, and the answer was "ask someone
# with database access".
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use experimental 'signatures';

use Test::Registry::DB;
use Registry::DAO;
use Registry::DAO::Location;
use Registry::DAO::Project;
use Registry::DAO::Event;
use Registry::DAO::Session;
use Registry::DAO::Enrollment;
use Registry::DAO::PricingPlan;
use Registry::DAO::Family;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $parent = $dao->create( User => {
    username => 'se_parent', name => 'SE Parent', user_type => 'parent',
    email => 'se@test.local' } );

my $n = 0;
sub a_session ( $capacity = 10 ) {
    $n++;
    my $loc = Registry::DAO::Location->create( $db, {
        name => "SE Loc $n$$", slug => "se_loc_$n$$", address_info => {}, metadata => {} } );
    my $proj = Registry::DAO::Project->create( $db, {
        name => "SE Proj $n$$", status => 'published',
        program_type_slug => 'summer-camp', metadata => {} } );
    my $teacher = $dao->create( User => {
        username => "se_t_$n$$", name => 'SE T', user_type => 'staff',
        email => "se_t_$n$$\@test.local" } );
    my $event = Registry::DAO::Event->create( $db, {
        location_id => $loc->id, project_id => $proj->id, teacher_id => $teacher->id,
        time => \'NOW()', duration => 60, capacity => $capacity, metadata => {} } );
    my $s = Registry::DAO::Session->create( $db, {
        name => "SE Session $n$$", status => 'published',
        capacity => $capacity, waitlist_enabled => 1, metadata => {} } );
    $s->add_events( $db, $event->id );
    return $s;
}

sub a_child () {
    $n++;
    return Registry::DAO::Family->add_child( $db, $parent->id, {
        child_name => "SE Kid $n", birth_date => '2015-01-01', grade => '4',
        medical_info => {}, emergency_contact => { name => 'x', phone => '5' } } );
}

sub enrol ( $session, $child ) {
    return Registry::DAO::Enrollment->create( $db, {
        session_id => $session->id, student_id => $child->id,
        parent_id => $parent->id, status => 'active' } );
}

sub reload ($session) {
    return Registry::DAO::Session->find( $db, { id => $session->id } );
}

subtest 'capacity and the waitlist toggle can both be changed' => sub {
    my $session = a_session(10);

    my $updated = $session->apply_settings( $db,
        { capacity => 20, waitlist_enabled => 0 } );

    is $updated->capacity, 20, 'the returned object carries the new capacity';
    is $updated->waitlist_enabled, 0, 'and the new waitlist setting';

    my $fresh = reload($session);
    is $fresh->capacity, 20, 'the row was written';
    is $fresh->waitlist_enabled, 0, 'both fields';
};

subtest 'capacity cannot be cut below the children already enrolled' => sub {
    # The edit the issue singles out as different in kind: turning a waitlist off
    # affects nobody who already has a seat, but cutting capacity under the
    # enrolled count would make the session over-subscribed by arithmetic, and
    # every seat check reads capacity.
    my $session = a_session(10);
    enrol( $session, a_child() ) for 1 .. 3;

    my $err = do { local $@;
        eval { $session->apply_settings( $db, { capacity => 2 } ) }; $@ };
    ok $err, 'refused';
    like $err, qr/3/, 'and says how many are enrolled';
    is reload($session)->capacity, 10, 'the capacity is unchanged';
};

subtest 'capacity can be cut as far as the enrolled count, but not past it' => sub {
    my $session = a_session(10);
    enrol( $session, a_child() ) for 1 .. 3;

    my $updated = $session->apply_settings( $db, { capacity => 3 } );
    is $updated->capacity, 3, 'exactly full is allowed';

    my $err = do { local $@;
        eval { $updated->apply_settings( $db, { capacity => 2 } ) }; $@ };
    ok $err, 'one below is not';
};

subtest 'raising capacity is always allowed' => sub {
    my $session = a_session(5);
    enrol( $session, a_child() ) for 1 .. 5;

    my $updated = $session->apply_settings( $db, { capacity => 12 } );
    is $updated->capacity, 12, 'a full session can be made bigger';
};

subtest 'a price change supersedes the plan rather than rewriting it' => sub {
    # The session's price is a versioned pricing_plans row. Mutating
    # amount_cents in place would rewrite what everyone who already paid was
    # charged under; revise() retires the old version and adds a new one.
    my $session = a_session(10);
    Registry::DAO::PricingPlan->create( $db, {
        session_id => $session->id, plan_name => 'Standard',
        plan_type => 'standard', amount_cents => 5000 } );

    $session->apply_settings( $db, { price_cents => 7500 } );

    my $plans = Registry::DAO::PricingPlan->get_pricing_plans( $db, $session->id );
    my @current = grep { !defined $_->superseded_at } @$plans;
    is scalar @current, 1, 'exactly one current version';
    is $current[0]->amount_cents, 7500, 'at the new price';

    my $history = $current[0]->versions($db);
    is scalar @$history, 2, 'and the old price is still on record';
    is $history->[0]->amount_cents, 5000, 'unchanged, as what someone actually paid';
};

subtest 'a session with no price yet gets one' => sub {
    # GenerateEvents only creates a plan when the override was filled in, so a
    # session can legitimately have none. Editing the price has to be able to
    # add the first one rather than failing on a missing plan.
    my $session = a_session(10);
    is scalar @{ Registry::DAO::PricingPlan->get_pricing_plans( $db, $session->id ) }, 0,
        'no plan to begin with';

    $session->apply_settings( $db, { price_cents => 4200 } );

    my $plans = Registry::DAO::PricingPlan->get_pricing_plans( $db, $session->id );
    my @current = grep { !defined $_->superseded_at } @$plans;
    is scalar @current, 1, 'a plan was created';
    is $current[0]->amount_cents, 4200, 'at the given price';
};

subtest 'a free session is a price, not a missing one' => sub {
    # An override of 0 is how GenerateEvents produces a free, registerable
    # session, so 0 has to be distinguishable from "leave the price alone".
    my $session = a_session(10);
    Registry::DAO::PricingPlan->create( $db, {
        session_id => $session->id, plan_name => 'Standard',
        plan_type => 'standard', amount_cents => 5000 } );

    $session->apply_settings( $db, { price_cents => 0 } );

    my $plans = Registry::DAO::PricingPlan->get_pricing_plans( $db, $session->id );
    my @current = grep { !defined $_->superseded_at } @$plans;
    is $current[0]->amount_cents, 0, 'free, rather than still five thousand';
};

subtest 'a negative price is refused' => sub {
    my $session = a_session(10);
    my $err = do { local $@;
        eval { $session->apply_settings( $db, { price_cents => -100 } ) }; $@ };
    ok $err, 'refused';
};

subtest 'an empty change is a no-op, not a wipe' => sub {
    my $session = a_session(7);
    my $updated = $session->apply_settings( $db, {} );
    is $updated->capacity, 7, 'capacity survives';
    is $updated->waitlist_enabled, 1, 'and so does the waitlist setting';
};

done_testing;
