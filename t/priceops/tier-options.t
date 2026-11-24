#!/usr/bin/env perl
# ABOUTME: The plans a prospect actually sees, asserted against the SHIPPED seed: the published Solo version alone.
# ABOUTME: t/controller/tenant-pricing-display.t publishes its own offers; this one must not.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::WorkflowSteps::PricingPlanSelection;
use Registry::PriceOps::RevenueShare;
use Mojo::File qw( path );

# The point of this file. The display test builds its own Solo/Studio/Empire
# fixtures, so it passed for as long as the machinery worked -- while the
# deployed database carried one plan called "Registry Revenue Share" and the
# coming-soon branch of the template had never once executed. A ladder that
# renders correctly from invented data says nothing about what a prospect sees.
#
# Everything below reads the seed the migrations actually ship.

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

# The plan-choice page left the signup funnel when Solo became the only tier on
# sale, so the step is built here rather than looked up in tenant-signup. What
# this file asserts: what the seed publishes, the rate it
# carries, and the refusal that keeps an unpublished tier from being bought.
my $workflow = Registry::DAO::Workflow->create( $db, {
    name        => 'Tier Ladder Probe',
    slug        => "tier-ladder-$$",
    description => 'Holds a PricingPlanSelection step outside the signup funnel',
} );

my $step = Registry::DAO::WorkflowSteps::PricingPlanSelection->create( $db, {
    workflow_id => $workflow->id,
    slug        => 'pricing',
    class       => 'Registry::DAO::WorkflowSteps::PricingPlanSelection',
    description => 'Select pricing plan',
} );
ok $step, 'the plan-choice step is available to render the ladder';

my $run   = $workflow->new_run($db);
my $plans = $step->prepare_pricing_data($db, $run)->{pricing_plans};

subtest 'the signup page offers exactly the published Solo version' => sub {
    is_deeply [ map { $_->{plan_name} } @$plans ], ['Solo'], 'Solo alone is on offer'
        or diag 'got: ' . join( ', ', map { $_->{plan_name} } @$plans );
    is $plans->[0]{id}, '00000000-0000-0000-0003-000000000001',
        'as the version the bootstrap publishes';
};

subtest 'the unpublished tiers cannot be bought, however they are posted' => sub {
    my %old = map { $_->{plan_name} => $_->{id} } $db->query( q{
        SELECT plan_name, id FROM registry.pricing_plans
         WHERE plan_name IN ('Studio', 'Empire') AND superseded_at IS NULL
    } )->hashes->@*;

    # Fatal precondition. Every refusal below would pass on an undef id.
    ok defined $old{Studio} && defined $old{Empire}, 'both old tier ids resolved' or return;

    ok $step->validate_plan_selection( $db, $plans->[0]{id} ), 'the published Solo version selects';
    ok !$step->validate_plan_selection( $db, $old{Studio} ), 'Studio is refused server-side';
    ok !$step->validate_plan_selection( $db, $old{Empire} ), 'and Empire likewise';
};

# The one place the launch DECISION is written down in a test.
#
# Everything else here reads the rate from the database and compares it to
# something else read from the database, which grades consistency and nothing
# else. A seed that said 0.25 would satisfy every one of those: still positive,
# still a fraction, still the largest of three, still equal to itself -- and the
# platform would take 25% of every customer payment while the copy promised 2.5.
#
# The rate is a decision, not a derived value, so it is pinned once, here, to
# the number the signup copy quotes.
subtest 'the launch rate is the rate the platform advertises' => sub {
    my $launch = Registry::PriceOps::RevenueShare::platform_launch_fraction($db);

    cmp_ok abs( $launch - 0.025 ), '<', 1e-9,
        'the launch rate is 2.5%';

    # And the static copy agrees with it. This is the loop the whole rate
    # exercise exists to close: a number in a template that nothing compares
    # against the database is how three rates came to be live at once.
    my $pct = 0 + sprintf '%g', $launch * 100;

    # Every template that quotes a rate, not just the one that prompted this.
    # Closing the loop on a single file makes a rate move update that file and
    # leave its siblings saying the old number -- which is the same drift, minus
    # one door. Adding marketing copy that quotes a rate means adding it here.
    for my $tpl (
        'templates/tenant-signup/index.html.ep',
        'templates/registry-storefront/landing.html.ep',
    ) {
        my $copy = path($tpl)->slurp;

        # (?<![\d.]) or "12.5%" satisfies a check for "2.5%" -- the typo the
        # assertion exists to catch would have passed it.
        like $copy, qr/(?<![\d.])\Q$pct\E%/,
            "$tpl quotes ${pct}%, the rate the platform actually charges";

        unlike $copy,
            qr/(?<![\d.])(?!\Q$pct\E%)\d+(?:\.\d+)?%\s+(?:of\s+)?(?:processed\s+)?revenue/,
            "$tpl quotes no other rate alongside it, in the phrasings this checks";
    }
};

subtest 'the buyable tier is the one carrying the advertised rate' => sub {
    my ($solo) = @$plans;

    my $launch = Registry::PriceOps::RevenueShare::platform_launch_fraction($db);
    cmp_ok abs( $solo->{pricing_configuration}{percentage} - $launch ), '<', 1e-9,
        'Solo charges the rate platform_launch_fraction advertises';

    # The signup copy quotes a rate; the page renders one; the charge path
    # resolves one. This is the seam where they were allowed to differ.
    ok $solo->{pricing_configuration}{percentage} > 0,
        'and it is not the Free-plan zero';
};

done_testing;
