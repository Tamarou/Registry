# ABOUTME: Tests that the storefront's advertised price is one a parent can actually be charged.
# ABOUTME: An expired early-bird plan used to set the advertised floor while the cart charged more.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::PricingPlan;
use Registry::DAO::Payment;
use Registry::DAO::Family;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $loc = $dao->create(Location => {
    name => 'Advertised Studio', slug => 'advertised-studio',
    address_info => {}, metadata => {},
});
my $prog = $dao->create(Project => {
    status => 'published', name => 'Advertised Camp',
    program_type_slug => 'summer-camp', metadata => {},
});
my $teacher = $dao->create(User => {
    username => 'adv_teacher', name => 'T', user_type => 'staff', email => 'at@test.local',
});
my $parent = $dao->create(User => {
    username => 'adv_parent', name => 'Advertised Parent', user_type => 'parent',
    email => 'ap@test.local',
});
my $kid = Registry::DAO::Family->add_child($db, $parent->id, {
    child_name => 'Advertised Kid', birth_date => '2018-01-01', grade => '3',
    medical_info => {}, emergency_contact => { name => 'x', phone => '5' },
});

# Dates derived, never pinned: the listing filters on end_date >= CURRENT_DATE,
# so a hardcoded date empties the page the day it passes (#368).
sub days_from_now ($n) {
    my @t = localtime( time + $n * 86_400 );
    return sprintf '%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3];
}

my $session = $dao->create(Session => {
    name => 'Advertised Week', start_date => days_from_now(30),
    end_date => days_from_now(37), status => 'published',
    capacity => 20, metadata => {},
});
my $event = $dao->create(Event => {
    time => days_from_now(30) . ' 09:00:00', duration => 420,
    location_id => $loc->id, project_id => $prog->id, teacher_id => $teacher->id,
    capacity => 20, metadata => {},
});
$session->add_events($db, $event->id);

# Standard $300, plus an early bird at $200 whose cutoff has passed. Nobody can
# be charged $200 for this session any more.
Registry::DAO::PricingPlan->create($db, {
    session_id => $session->id, plan_name => 'Standard',
    plan_type => 'standard', amount_cents => 30000,
});
Registry::DAO::PricingPlan->create($db, {
    session_id => $session->id, plan_name => 'Early Bird',
    plan_type => 'early_bird', amount_cents => 20000,
    requirements => { early_bird_cutoff_date => '2020-01-01' },
});

my $workflow = Registry::DAO::Workflow->create($db, {
    name => 'Advertised Storefront', slug => 'advertised-storefront',
    description => 'Lists programmes',
});
Registry::DAO::WorkflowStep->create($db, {
    workflow_id => $workflow->id, slug => 'program-listing',
    class => 'Registry::DAO::WorkflowSteps::ProgramListing',
    description => 'Browse Available Programs',
});
$workflow->update($db, { first_step => 'program-listing' }, { id => $workflow->id });
$workflow = Registry::DAO::Workflow->find($db, { id => $workflow->id });

my $step = $workflow->first_step($db);
my $run  = $workflow->new_run($db);

subtest 'the advertised price is one the cart will actually charge' => sub {
    my $data = $step->prepare_template_data($db, $run, {});

    # grouped_programs is { type_slug => [ program, ... ] }, each program with a
    # sessions list -- the shape the template walks.
    my ($listed) =
      grep { $_->{session}->id eq $session->id }
      map  { @{ $_->{sessions} } }
      map  { @$_ }
      values %{ $data->{grouped_programs} || {} };

    ok $listed, 'the session is listed on the storefront';

    # The storefront took MIN(amount_cents) across every plan on the session,
    # applicable or not, so a closed early bird set the advertised floor: the card
    # read "From $200" and the cart charged $300.
    is $listed->{best_price_cents}, 30000,
        'the closed early bird does not set the advertised price';
    # "$300", not "From $300": once the closed early bird is excluded there is
    # exactly one price on offer, and "From" implies a cheaper one exists.
    is $listed->{best_price}, '$300',
        'and the card reads the price a parent can get, without a false "From"';

    # Asserted against the cart rather than against a number typed twice: these
    # two have to agree, and agreeing by coincidence is what went wrong.
    my $quote = Registry::DAO::Payment->calculate_enrollment_total($db, {
        children => [ { id => $kid->id, first_name => 'Advertised Kid',
                        last_name => '', grade => '3' } ],
        session_selections => { $kid->id => $session->id },
    });
    is $listed->{best_price_cents}, $quote->{total},
        'the advertised price equals what the cart quotes for one child';
};

subtest '"From" comes back when more than one price is really available' => sub {
    # Re-open the early bird. Two plans now apply, so the cheaper one is the
    # advertised floor and "From" is true.
    $db->query(
        q{UPDATE pricing_plans SET requirements = ?::jsonb
           WHERE session_id = ? AND plan_type = 'early_bird'},
        '{"early_bird_cutoff_date":"2030-01-01"}', $session->id );

    my $data = $step->prepare_template_data($db, $run, {});
    my ($listed) =
      grep { $_->{session}->id eq $session->id }
      map  { @{ $_->{sessions} } }
      map  { @$_ }
      values %{ $data->{grouped_programs} || {} };

    is $listed->{best_price_cents}, 20000, 'the open early bird is the floor';
    is $listed->{best_price}, 'From $200', 'and "From" says there is a choice';

    my $quote = Registry::DAO::Payment->calculate_enrollment_total($db, {
        children => [ { id => $kid->id, first_name => 'Advertised Kid',
                        last_name => '', grade => '3' } ],
        session_selections => { $kid->id => $session->id },
    });
    is $listed->{best_price_cents}, $quote->{total},
        'and the cart charges exactly what was advertised';
};

done_testing;
