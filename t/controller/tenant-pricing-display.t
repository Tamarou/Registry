# ABOUTME: Tests the plan-choice step's data and rendering, and that the review page lists the published plan.
# ABOUTME: The plan-choice page is out of the signup funnel; the step class lists the platform's published offers.
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
use Test::Registry::Helpers;
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

# No plan fixtures: this file renders what the shipped seed publishes, which
# on day one is Solo alone. Studio and Empire survive only as legacy
# registry.pricing_plans rows, never published, so they must never be offered.
my $solo_version_id = platform_solo_offer_version_id($db);
my ($studio_plan_id, $empire_plan_id) = map {
    $db->db->query(
        'SELECT id FROM registry.pricing_plans WHERE plan_name = ? AND plan_scope = ?',
        $_, 'tenant' )->array->[0]
} qw( Studio Empire );

ok $studio_plan_id && $empire_plan_id, 'the legacy Studio and Empire plans still exist';

# The plan-choice page left the signup funnel when Solo became the only tier on
# sale. The step class and its template stay, listing the platform's published
# offers, so the step is built here directly rather than reached through
# tenant-signup.
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
    is_deeply [ map { $_->{plan_name} } @$plans ], ['Solo'], 'the published Solo version alone';
    is $plans->[0]{id}, $solo_version_id, 'by its version id';
};

# Studio and Empire were never published as offers, so posting their legacy
# plan ids directly must be refused server-side.
subtest 'an unpublished plan cannot be selected, however it is posted' => sub {
    my $step = $choice_step;

    ok !$step->validate_plan_selection( $db->db, $studio_plan_id ), 'Studio is refused';
    ok !$step->validate_plan_selection( $db->db, $empire_plan_id ), 'Empire is refused too';
    ok $step->validate_plan_selection( $db->db, $solo_version_id ),
        'and the published Solo version selects';

    my $run = $choice_workflow->new_run($db->db);
    my $result = $step->process( $db->db,
        { selected_plan_id => $studio_plan_id }, $run );

    ok $result->{_validation_errors},
        'processing the step with an unpublished plan is rejected';
    ok !$run->data->{selected_offer_version},
        'and nothing is written to the run';
};

subtest 'the plan-choice template renders the plans it is given' => sub {
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

    like $html, qr/data-plan="Solo"/, 'renders the Solo card';
    unlike $html, qr/data-plan="(?:Studio|Empire)"/, 'and no unpublished tier';
    like $html, qr/<input[^>]*name="selected_plan_id"/,
        'renders a plan selection radio';
};

subtest 'the review page lists the published plan, preselected' => sub {
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
      ->element_exists(qq{input[name="offer_version"][value="$solo_version_id"][checked]},
            'review page preselects the published Solo version')
      ->content_like(qr{<strong>Solo</strong>}, 'and names it')
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
