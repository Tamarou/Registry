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
        'Solo, Studio, Empire';

    # The sort key itself. display_order and amount_cents happen to be monotone
    # in the same direction, so the order above cannot tell which one produced
    # it -- prepare_pricing_data falls back to amount_cents when display_order
    # is absent, and the list comes out identical either way.
    is_deeply [ map { $_->{metadata}{display_order} } @$plans ], [ 1, 2, 3 ],
        'and every tier carries an explicit display_order, which is what sorts them';
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

    # Fatal precondition. validate_plan_selection returns early on a falsy id,
    # so every refusal below would pass on an undef -- and these four lines are
    # the whole mutation surface for the guard this ladder depends on.
    ok defined $solo->{id} && defined $studio->{id} && defined $empire->{id},
        'all three tier ids resolved' or return;

    ok $step->validate_plan_selection( $db, $solo->{id} ),
        'the launched tier selects';
    ok !$step->validate_plan_selection( $db, $studio->{id} ),
        'Studio is refused server-side, not merely greyed out';
    ok !$step->validate_plan_selection( $db, $empire->{id} ),
        'and Empire likewise';
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
        'templates/registry/tenant-storefront-program-listing.html.ep',
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
