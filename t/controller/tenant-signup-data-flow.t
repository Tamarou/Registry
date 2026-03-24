# ABOUTME: Tests that tenant-signup workflow persists form data across steps
# ABOUTME: and that the review step correctly reads accumulated run data.
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

# Setup test database
my $t_db = Test::Registry::DB->new;
my $db = $t_db->db;

# Import workflows
$db->import_workflows(['workflows/tenant-signup.yml']);

# Create test app with test DB
my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $db });

# Set tenant context
$db->current_tenant('registry');

subtest 'pricing template does not use hx-post on main form' => sub {
    my $root = curfile->dirname->dirname->dirname;
    my $content = $root->child('templates/tenant-signup/pricing.html.ep')->slurp;

    # The main form should use standard POST, not HTMX body swap.
    # hx-post on the main form causes HTMX to intercept the submit,
    # follow the 302 redirect, and swap the full next-page HTML into
    # hx-target, nesting the page instead of replacing it (GitHub #122).
    # The form tag should not contain any hx-post attribute at all.
    # Standard form POST with browser navigation is the correct approach.
    unlike($content, qr/<form[^>]*\bhx-post\b/s,
        'pricing form does not have hx-post attribute');
};

subtest 'review template reads data from stash correctly' => sub {
    my $root = curfile->dirname->dirname->dirname;
    my $content = $root->child('templates/tenant-signup/review.html.ep')->slurp;

    # TenantSignupReview::prepare_template_data returns { profile => ..., team => ... }
    # which gets spread into the stash via %$template_data in the controller.
    # The template must read stash('profile'), NOT stash('data')->{profile}.
    # Using stash('data') yields {} because no 'data' key is set (GitHub #123).
    like($content, qr/stash\(['"]profile['"]\)/,
        'review template reads profile directly from stash');
    unlike($content, qr/my \$data = stash\(['"]data['"]\)/,
        'review template does not read from stash data key');
};

subtest 'profile data persists through workflow and appears on review step' => sub {
    # Start a new tenant-signup workflow
    $t->post_ok('/tenant-signup')
      ->status_is(302);

    my $redirect = $t->tx->res->headers->location;
    like($redirect, qr{/tenant-signup/[^/]+/profile}, 'redirects to profile step');

    # GET the profile page first (to establish session/CSRF)
    $t->get_ok($redirect)->status_is(200);

    # Submit profile data (billing address handled by Stripe Connect)
    $t->post_ok($redirect => form => {
        name            => 'Portland Art Collective',
        description     => 'Art classes for all ages',
        billing_email   => 'billing@portlandart.com',
    })->status_is(302);

    my $users_url = $t->tx->res->headers->location;
    like($users_url, qr{/tenant-signup/[^/]+/users}, 'redirects to users step');

    # GET the users page
    $t->get_ok($users_url)->status_is(200);

    # Submit users/team data
    $t->post_ok($users_url => form => {
        admin_name      => 'Jane Artist',
        admin_email     => 'jane@portlandart.com',
        admin_username  => 'janeartist',
        admin_password  => 'securepass123',
        admin_user_type => 'admin',
    })->status_is(302);

    my $pricing_url = $t->tx->res->headers->location;
    like($pricing_url, qr{/tenant-signup/[^/]+/pricing}, 'redirects to pricing step');

    # GET the pricing page
    $t->get_ok($pricing_url)->status_is(200);

    # Submit pricing step (no plan to select since none are configured)
    $t->post_ok($pricing_url => form => {})
      ->status_is(302);

    my $review_url = $t->tx->res->headers->location;
    like($review_url, qr{/tenant-signup/[^/]+/review}, 'redirects to review step');

    # GET the review page and verify accumulated data is displayed
    $t->get_ok($review_url)
      ->status_is(200)
      ->content_like(qr/Portland Art Collective/,
          'review page shows organization name from profile step')
      ->content_like(qr/billing\@portlandart\.com/,
          'review page shows billing email from profile step')
      ->content_like(qr/Jane Artist/,
          'review page shows admin name from users step')
      ->content_like(qr/jane\@portlandart\.com/,
          'review page shows admin email from users step')
      ->content_like(qr/janeartist/,
          'review page shows admin username from users step');
};
