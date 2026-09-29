# ABOUTME: Tests the plan-choice step's data and rendering, and that the review page states the plan.
# ABOUTME: The plan-choice page is out of the signup funnel until a paid tier launches; the step class is not.
use 5.42.0;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw( done_testing is ok like unlike is_deeply subtest cmp_ok )];
defer { done_testing };

use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Mojo::File qw(curfile);

use Registry;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::PricingPlan;
use Registry::DAO::PricingRelationship;
use Registry::DAO::WorkflowSteps::PricingPlanSelection;

# Setup test database
my $t_db = Test::Registry::DB->new;
my $db = $t_db->db;

# Import workflows
$db->import_workflows(['workflows/tenant-signup.yml']);

# Create test app with test DB
my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $db });
$db->current_tenant('registry');

# No plan fixtures. This file used to seed its own Solo/Studio/Empire, which is
# why it stayed green for as long as the rendering worked -- while the deployed
# database carried a single plan called "Registry Revenue Share" and the
# coming-soon branch below had never executed against real data. A page that
# renders invented tiers correctly says nothing about what a prospect sees.
#
# seed-tier-pricing-options ships the ladder now, so this file renders the real
# one. t/priceops/tier-options.t asserts the seed's shape; this one asserts what
# the template does with it.
my $platform_uuid = '00000000-0000-0000-0000-000000000000';

my ($solo_plan_id, $studio_plan_id, $empire_plan_id) = map {
    $db->db->query(
        'SELECT id FROM registry.pricing_plans WHERE plan_name = ? AND plan_scope = ?',
        $_, 'tenant' )->array->[0]
} qw( Solo Studio Empire );

ok $solo_plan_id && $studio_plan_id && $empire_plan_id,
    'the shipped seed provides the Solo/Studio/Empire ladder';

# The plan-choice page left the signup funnel when Solo became the only tier on
# sale: it offered one real choice and two server-side refusals. The step class
# and its template stay for the day Studio or Empire launches, so the step is
# built here directly rather than reached through tenant-signup.
my $choice_workflow = Registry::DAO::Workflow->create($db->db, {
    name        => 'Plan Choice Probe',
    slug        => "plan-choice-$$",
    description => 'Holds a PricingPlanSelection step outside the signup funnel',
});
my $choice_step = Registry::DAO::WorkflowSteps::PricingPlanSelection->create($db->db, {
    workflow_id => $choice_workflow->id,
    slug        => 'pricing',
    class       => 'Registry::DAO::WorkflowSteps::PricingPlanSelection',
    description => 'Select pricing plan',
});

subtest 'PricingPlanSelection provides plans via prepare_template_data' => sub {
    my $run = $choice_workflow->new_run($db->db);
    $run->update_data($db->db, {
        name => 'Test Org', billing_email => 'test@test.com',
        admin_name => 'Test Admin', admin_email => 'admin@test.com',
        admin_username => 'testadmin',
    });

    my $template_data = $choice_step->prepare_template_data($db->db, $run);
    ok $template_data->{pricing_plans}, 'template data includes pricing_plans';

    my $plans = $template_data->{pricing_plans};
    cmp_ok scalar(@$plans), '>=', 3, 'at least the three test plans are returned (plus any seeded platform plans)';
    is $plans->[0]{plan_name}, 'Solo', 'first plan is Solo (sorted by display_order)';
    is $plans->[1]{plan_name}, 'Studio', 'second plan is Studio';
    is $plans->[2]{plan_name}, 'Empire', 'third plan is Empire';

    # Coming-soon metadata is passed through
    ok $plans->[1]{metadata}{coming_soon}, 'Studio is marked coming_soon';
    ok $plans->[2]{metadata}{coming_soon}, 'Empire is marked coming_soon';
    ok !$plans->[0]{metadata}{coming_soon}, 'Solo is not coming_soon';
};

# A greyed-out card is CSS. The plan still has an active relationship -- it must,
# or prepare_pricing_data would not return it to be rendered at all -- so the
# only thing standing between a client and a tier the business has not launched
# is the disabled attribute on a radio button. Posting the id directly skips it.
#
# The cost is not cosmetic: Studio and Empire carry a monthly base, so a signup
# on one of them creates a subscription for a product that does not exist yet.
subtest 'a coming-soon plan cannot be selected, however it is posted' => sub {
    my $step = $choice_step;

    ok !$step->validate_plan_selection( $db->db, $studio_plan_id ),
        'Studio is refused: it is on offer to look at, not to buy';
    ok !$step->validate_plan_selection( $db->db, $empire_plan_id ),
        'Empire is refused too';

    ok $step->validate_plan_selection( $db->db, $solo_plan_id ),
        'and the tier that IS launched still selects';

    my $run = $choice_workflow->new_run($db->db);
    my $result = $step->process( $db->db,
        { selected_plan_id => $studio_plan_id }, $run );

    ok $result->{_validation_errors},
        'processing the step with a coming-soon plan is rejected';
    ok !$run->data->{selected_pricing_plan},
        'and nothing is written to the run';
};

subtest 'the plan-choice template renders the ladder it is given' => sub {
    # Rendered directly rather than fetched: the page has no URL in the signup
    # funnel any more. The attributes below are the escaping fix -- the card
    # markup carries the plan identity, not just its styling.
    my $run = $choice_workflow->new_run($db->db);
    my $html = $t->app->build_controller->render_to_string(
        template => 'tenant-signup/pricing',
        action   => '/plan-choice-probe',
        run      => $run,
        %{ $choice_step->prepare_pricing_data($db->db, $run) },
    );

    like $html, qr/data-plan="Solo"/,   'renders the Solo card';
    like $html, qr/data-plan="Studio"/, 'renders the Studio card';
    like $html, qr/data-plan="Empire"/, 'renders the Empire card';
    like $html, qr/<input[^>]*name="selected_plan_id"/,
        'renders a plan selection radio';
    like $html, qr/Coming Soon/, 'badges the unlaunched tiers';
    like $html, qr/<article[^>]*data-coming-soon="true"/,
        'marks coming-soon cards';
    like $html, qr/<article[^>]*data-featured="true"/,
        'and marks the featured card -- the other half of the same escaping fix';
};

subtest 'the review page states the plan the tenant will be put on' => sub {
    $t->post_ok('/tenant-signup')->status_is(302);
    my $url = $t->tx->res->headers->location;
    $t->get_ok($url)->status_is(200);
    $t->post_ok($url => form => {
        name => 'Pricing Test Org', billing_email => 'price@test.com',
    })->status_is(302);

    $url = $t->tx->res->headers->location;
    $t->get_ok($url)->status_is(200);
    $t->post_ok($url => form => {
        admin_name => 'Price Admin', admin_email => 'price@test.com',
        admin_username => 'priceadmin',
    })->status_is(302);

    my $review_url = $t->tx->res->headers->location;
    like $review_url, qr{/review$}, 'users step leads straight to review';

    $t->get_ok($review_url)
      ->status_is(200)
      ->content_like(qr{<div class="pricing-badge">\s*Solo},
            'review page names the plan, resolved rather than chosen')
      ->content_unlike(qr/\$200\/month/, 'review page does not hardcode $200/month');
};

subtest 'review template does not hardcode pricing' => sub {
    my $root = curfile->dirname->dirname->dirname;
    my $content = $root->child('templates/tenant-signup/review.html.ep')->slurp;

    unlike $content, qr/\$200\/month/,
        'review template does not contain hardcoded $200/month';
    unlike $content, qr/\$200 per month/,
        'review template does not contain hardcoded $200 per month';
    unlike $content, qr/Monthly billing at \$200/,
        'review template does not contain hardcoded billing terms';
};

subtest 'pricing template uses TinyArtEmpire branding' => sub {
    my $root = curfile->dirname->dirname->dirname;
    my $content = $root->child('templates/tenant-signup/pricing.html.ep')->slurp;

    unlike $content, qr/Registry plan/i,
        'pricing template does not reference "Registry plan"';
};
