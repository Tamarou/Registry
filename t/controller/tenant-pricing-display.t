# ABOUTME: Tests that pricing plans display on the pricing step and selected plan
# ABOUTME: data flows through to the review step dynamically (not hardcoded).
use 5.42.0;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw( done_testing is ok like unlike is_deeply subtest )];
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

# Seed platform pricing plans matching Solo/Studio/Empire tier structure
my $platform_uuid = '00000000-0000-0000-0000-000000000000';

# Create platform user for pricing relationships
my $platform_user_id = $db->db->query('SELECT gen_random_uuid()')->array->[0];
$db->db->query(q{
    INSERT INTO registry.users (id, username, passhash, user_type)
    VALUES (?, ?, ?, ?)
}, $platform_user_id, 'platform_admin_pricing', '$2b$12$DummyHash', 'admin');
$db->db->query(q{
    INSERT INTO registry.user_profiles (user_id, email, name)
    VALUES (?, ?, ?)
}, $platform_user_id, 'admin@tinyartempire.com', 'Platform Admin');
$db->db->query(q{
    INSERT INTO registry.tenant_users (tenant_id, user_id, is_primary)
    VALUES (?, ?, ?)
}, $platform_uuid, $platform_user_id, 1);

my $solo_plan = Registry::DAO::PricingPlan->create($db->db, {
    plan_name  => 'Solo',
    plan_type  => 'standard',
    plan_scope => 'tenant',
    pricing_model_type => 'percentage',
    amount     => 0,
    currency   => 'USD',
    pricing_configuration => {
        revenue_share_percent => 2.5,
        billing_cycle => 'monthly',
        description   => '2.5% of processed revenue. No monthly fee.',
        features      => [
            'Unlimited programs',
            'Online enrollment',
            'Payment processing',
            'Attendance tracking',
            'Waitlist management',
        ],
    },
    metadata => { display_order => 1, featured => 1 },
});

Registry::DAO::PricingRelationship->create($db->db, {
    provider_id     => $platform_uuid,
    consumer_id     => $platform_user_id,
    pricing_plan_id => $solo_plan->id,
    status          => 'active',
    metadata        => { plan_type => 'tenant_subscription' },
});

my $studio_plan = Registry::DAO::PricingPlan->create($db->db, {
    plan_name  => 'Studio',
    plan_type  => 'standard',
    plan_scope => 'tenant',
    pricing_model_type => 'hybrid',
    amount     => 19900,
    currency   => 'USD',
    pricing_configuration => {
        revenue_share_percent => 2,
        billing_cycle => 'monthly',
        description   => '$199/mo + 2% of processed revenue.',
        features      => [
            'Everything in Solo',
            'Team seats (up to 5)',
            'Priority email support',
            'Advanced analytics',
        ],
    },
    metadata => { display_order => 2, coming_soon => 1 },
});

Registry::DAO::PricingRelationship->create($db->db, {
    provider_id     => $platform_uuid,
    consumer_id     => $platform_user_id,
    pricing_plan_id => $studio_plan->id,
    status          => 'active',
    metadata        => { plan_type => 'tenant_subscription' },
});

my $empire_plan = Registry::DAO::PricingPlan->create($db->db, {
    plan_name  => 'Empire',
    plan_type  => 'standard',
    plan_scope => 'tenant',
    pricing_model_type => 'hybrid',
    amount     => 99900,
    currency   => 'USD',
    pricing_configuration => {
        revenue_share_percent => 1,
        billing_cycle => 'monthly',
        description   => '$999/mo + 1% of processed revenue.',
        features      => [
            'Everything in Studio',
            'Unlimited team seats',
            'White-label branding',
            'Full API access',
            'Dedicated support',
        ],
    },
    metadata => { display_order => 3, coming_soon => 1 },
});

Registry::DAO::PricingRelationship->create($db->db, {
    provider_id     => $platform_uuid,
    consumer_id     => $platform_user_id,
    pricing_plan_id => $empire_plan->id,
    status          => 'active',
    metadata        => { plan_type => 'tenant_subscription' },
});

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
        admin_username => 'testadmin', admin_password => 'pass1234',
    });

    my $pricing_step = $run->next_step($db->db);
    ok $pricing_step, 'reached pricing step';

    my $template_data = $pricing_step->prepare_template_data($db->db, $run);
    ok $template_data->{pricing_plans}, 'template data includes pricing_plans';

    my $plans = $template_data->{pricing_plans};
    is scalar(@$plans), 3, 'three pricing plans returned';
    is $plans->[0]{plan_name}, 'Solo', 'first plan is Solo (sorted by display_order)';
    is $plans->[1]{plan_name}, 'Studio', 'second plan is Studio';
    is $plans->[2]{plan_name}, 'Empire', 'third plan is Empire';

    # Coming-soon metadata is passed through
    ok $plans->[1]{metadata}{coming_soon}, 'Studio is marked coming_soon';
    ok $plans->[2]{metadata}{coming_soon}, 'Empire is marked coming_soon';
    ok !$plans->[0]{metadata}{coming_soon}, 'Solo is not coming_soon';
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
        admin_username => 'priceadmin', admin_password => 'pass1234',
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
        selected_plan_id => $solo_plan->id,
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
