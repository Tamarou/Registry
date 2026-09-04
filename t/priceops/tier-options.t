#!/usr/bin/env perl
# ABOUTME: The tier ladder a prospect actually sees, asserted against the SHIPPED seed.
# ABOUTME: t/controller/tenant-pricing-display.t seeds its own Solo/Studio/Empire; this one must not.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::PriceOps::RevenueShare;

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

# The workflow lives in a YAML file, not in the schema dump.
$dao->import_workflows(['workflows/tenant-signup.yml']);

my $workflow = $dao->find( Workflow => { slug => 'tenant-signup' } );
ok $workflow, 'the tenant-signup workflow is imported';

my $step = Registry::DAO::WorkflowStep->find( $db,
    { workflow_id => $workflow->id, slug => 'pricing' } );
ok $step, 'it has a pricing step';

my $run   = $workflow->new_run($db);
my $plans = $step->prepare_pricing_data($db, $run)->{pricing_plans};

subtest 'the signup page offers the tier ladder, in order' => sub {
    is scalar @$plans, 3, 'three tiers are on offer'
        or diag 'got: ' . join( ', ', map { $_->{plan_name} } @$plans );

    is_deeply [ map { $_->{plan_name} } @$plans ], [qw( Solo Studio Empire )],
        'Solo, Studio, Empire -- sorted by display_order, not by price';
};

subtest 'one tier is buyable and the rest anchor it' => sub {
    my ($solo, $studio, $empire) = @$plans;

    ok !$solo->{metadata}{coming_soon},   'Solo is buyable';
    ok $studio->{metadata}{coming_soon},  'Studio is an anchor';
    ok $empire->{metadata}{coming_soon},  'Empire is an anchor';

    # The ladder only anchors if the prices climb. A free tier beside two other
    # free tiers is not a price ladder, it is three identical cards.
    cmp_ok $solo->{amount_cents},   '<', $studio->{amount_cents},
        'Studio costs more than Solo';
    cmp_ok $studio->{amount_cents}, '<', $empire->{amount_cents},
        'and Empire more than Studio';

    # And the revenue share falls as the base rises -- that is the trade the
    # ladder is selling. If it ever inverts, the anchors argue against upgrading.
    my @rates = map { $_->{pricing_configuration}{percentage} } @$plans;
    cmp_ok $rates[0], '>', $rates[1], 'Studio takes a smaller share than Solo';
    cmp_ok $rates[1], '>', $rates[2], 'and Empire smaller than Studio';
};

subtest 'the anchors cannot be bought, however they are posted' => sub {
    my ($solo, $studio, $empire) = @$plans;

    ok $step->validate_plan_selection( $db, $solo->{id} ),
        'the launched tier selects';
    ok !$step->validate_plan_selection( $db, $studio->{id} ),
        'Studio is refused server-side, not merely greyed out';
    ok !$step->validate_plan_selection( $db, $empire->{id} ),
        'and Empire likewise';
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
