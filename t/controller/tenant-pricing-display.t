# ABOUTME: Tests that pricing plans display on the pricing step and selected plan
# ABOUTME: data flows through to the review step dynamically (not hardcoded).
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

subtest 'PricingPlanSelection provides plans via prepare_template_data' => sub {
    my $workflow = $db->find(Workflow => { slug => 'tenant-signup' });
    my $step = Registry::DAO::WorkflowStep->find($db->db, {
        workflow_id => $workflow->id,
        slug        => 'pricing',
    });
    ok $step, 'found pricing step';

    # Create a run and advance to pricing step
    my $run = $workflow->new_run($db->db);
    # Process through landing, profile, users to reach pricing
    my $landing = $workflow->first_step($db->db);
    $run->process($db->db, $landing, {});
    my $profile_step = $run->next_step($db->db);
    $run->process($db->db, $profile_step, { name => 'Test Org', billing_email => 'test@test.com' });
    my $users_step = $run->next_step($db->db);
    $run->process($db->db, $users_step, {
        admin_name => 'Test Admin', admin_email => 'admin@test.com',
        admin_username => 'testadmin',
    });

    my $pricing_step = $run->next_step($db->db);
    ok $pricing_step, 'reached pricing step';

    my $template_data = $pricing_step->prepare_template_data($db->db, $run);
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
    my $workflow = $db->find(Workflow => { slug => 'tenant-signup' });
    my $step = Registry::DAO::WorkflowStep->find($db->db, {
        workflow_id => $workflow->id,
        slug        => 'pricing',
    });

    ok !$step->validate_plan_selection( $db->db, $studio_plan_id ),
        'Studio is refused: it is on offer to look at, not to buy';
    ok !$step->validate_plan_selection( $db->db, $empire_plan_id ),
        'Empire is refused too';

    ok $step->validate_plan_selection( $db->db, $solo_plan_id ),
        'and the tier that IS launched still selects';

    my $run = $workflow->new_run($db->db);
    my $result = $step->process( $db->db,
        { selected_plan_id => $studio_plan_id }, $run );

    ok $result->{_validation_errors},
        'processing the step with a coming-soon plan is rejected';
    ok !$run->data->{selected_pricing_plan},
        'and nothing is written to the run';
};

subtest 'pricing step renders plan cards with coming-soon styling' => sub {
    # Start workflow and advance to pricing
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

    my $pricing_url = $t->tx->res->headers->location;
    like $pricing_url, qr{/pricing$}, 'reached pricing step';

    $t->get_ok($pricing_url)
      ->status_is(200)
      ->content_like(qr/Solo/, 'pricing page shows Solo plan')
      ->content_like(qr/Studio/, 'pricing page shows Studio plan')
      ->content_like(qr/Empire/, 'pricing page shows Empire plan')
      ->content_like(qr/selected_plan_id/, 'pricing page has plan selection radio buttons')
      ->content_like(qr/Coming Soon/, 'pricing page shows Coming Soon badges')
      ->content_like(qr/data-coming-soon/, 'pricing page marks coming-soon cards');
};

subtest 'selected plan appears on review step dynamically' => sub {
    # Continue from previous subtest - select the Solo plan
    my $pricing_url = $t->tx->req->url->path->to_string;
    $t->post_ok($pricing_url => form => {
        selected_plan_id => $solo_plan_id,
    })->status_is(302);

    my $review_url = $t->tx->res->headers->location;
    like $review_url, qr{/review$}, 'reached review step';

    $t->get_ok($review_url)
      ->status_is(200)
      ->content_like(qr/Solo/, 'review page shows selected plan name')
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
