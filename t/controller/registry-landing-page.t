#!/usr/bin/env perl
# ABOUTME: Tests the registry tenant's customized landing page for Jordan's journey.
# ABOUTME: Verifies hero, problem cards, alignment section, and callcc CTA render correctly.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Registry::PriceOps::RevenueShare;
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Helpers qw( join_tenant );
use Test::Registry::SoloVersion qw( publish_solo_version );
use Test::Registry::Fixtures;

use Registry::DAO qw(Workflow);
use Registry::DAO::Template;
use Mojo::Home;
use Mojo::File;
use YAML::XS qw(Load);

my $template_file = 'templates/registry-storefront/landing.html.ep';
plan skip_all => "Template file $template_file not found" unless -f $template_file;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

# Import all workflows
my @files = Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;
for my $file (@files) {
    next if Load($file->slurp)->{draft};
    Workflow->from_yaml($dao, $file->slurp);
}

# Import all templates from filesystem (seeds the DB)
my @tmpl_files = Mojo::Home->new->child('templates')->list_tree->grep(qr/\.html\.ep$/)->each;
for my $file (@tmpl_files) {
    Registry::DAO::Template->import_from_file($dao, $file);
}

# Seed registry-like data: project with registration_workflow metadata
my $location = $dao->create(Location => { time_zone => 'America/New_York',
    name => 'Online RegLP Test', slug => 'online-reglp-test',
    address_info => { type => 'virtual' }, metadata => {},
});
my $teacher = $dao->create(User => { username => 'system-reg-test', user_type => 'staff' });
my $project = $dao->create(Project => { status => 'published',
    name => 'Tiny Art Empire RegLP', slug => 'tiny-art-empire-reglp',
    notes => 'Platform for art educators',
    metadata => { registration_workflow => 'tenant-signup' },
});
my $session = $dao->create(Session => {
    name => 'Get Started', slug => 'get-started-reg-test',
    start_date => days_from_now(-30), end_date => days_from_now(3650),
    status => 'published', capacity => 999999, metadata => {},
});
my $event = $dao->create(Event => {
    time => days_from_now(-30) . ' 00:00:00', duration => 0,
    location_id => $location->id, project_id => $project->id,
    teacher_id => $teacher->id, capacity => 999999, metadata => {},
});
$session->add_events($dao->db, $event->id);

# Load the registry landing page template into the DB
my $template_content = Mojo::File->new($template_file)->slurp;
$dao->db->update('templates',
    { content => $template_content },
    { name => 'tenant-storefront/program-listing' },
);

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper(dao => sub { $dao });

# ============================================================
# Test 1: Landing page renders with vaporwave design system
# ============================================================
subtest 'landing page renders with vaporwave design system' => sub {
    $t->get_ok('/')
      ->status_is(200);

    $t->element_exists('.landing-page', 'Landing page container present')
      ->element_exists('.landing-hero', 'Hero section present')
      ->element_exists('.landing-cta-button', 'CTA button present');

    # No Tailwind classes
    $t->content_unlike(qr/class="[^"]*bg-white/, 'No Tailwind classes');

    # No broken template escaping
    $t->content_unlike(qr/%%/, 'No literal %% in rendered output');
};

# ============================================================
# Test 2: Hero section has headline and subtitle
# ============================================================
subtest 'hero section has headline and subtitle' => sub {
    $t->get_ok('/')
      ->status_is(200);

    $t->element_exists('.landing-hero h1', 'Hero headline exists')
      ->element_exists('.landing-hero-subtitle', 'Hero subtitle exists');

    $t->text_like('.landing-hero h1', qr/Your art deserves a real business/,
        'Hero headline has correct copy');

    # CTA links to tenant-signup
    my $dom = $t->tx->res->dom;
    my $cta = $dom->at('form[action*="callcc"]');
    ok $cta, 'callcc form found';
    if ($cta) {
        like $cta->attr('action'), qr{/callcc/tenant-signup},
            'CTA targets tenant-signup workflow';
    }
};

# ============================================================
# Test 3: Problem cards section exists with 6 cards
# ============================================================
subtest 'problem cards section exists with 6 cards' => sub {
    $t->get_ok('/')
      ->status_is(200);

    $t->element_exists('.landing-features', 'Features section present')
      ->element_exists('.landing-feature-card', 'At least one feature card present');

    my $dom = $t->tx->res->dom;
    my $cards = $dom->find('.landing-feature-card');
    is $cards->size, 6, 'Six problem cards rendered';
};

# ============================================================
# Test 4: Alignment section with pricing
# ============================================================
subtest 'alignment section with pricing' => sub {
    $t->get_ok('/')
      ->status_is(200);

    # Resolved, not restated. A literal here pins the page against itself: move
    # the launch rate and this test keeps passing on the old number while the
    # page keeps quoting it. t/priceops/tier-options.t holds the one place the
    # rate's value is written down.
    my $pct = 0 + sprintf '%g',
        Registry::PriceOps::RevenueShare::platform_offered_fraction(
            $t->app->dao->db ) * 100;

    $t->content_like(qr/(?<![\d.])\Q$pct\E%/,
        "revenue share shown as ${pct}%, the rate the platform charges")
      ->content_like(qr/Free to Start/i, 'Free to start messaging visible');
};

# ============================================================
# Test 5: CTA button says Get Started
# ============================================================
subtest 'CTA button text' => sub {
    $t->get_ok('/')
      ->status_is(200);

    $t->text_like('.landing-cta-button', qr/Get Started/i, 'CTA says Get Started');
};

# ============================================================
# Test 6: No raw session data exposed
# ============================================================
subtest 'no raw session data on landing page' => sub {
    $t->get_ok('/')
      ->status_is(200);

    $t->content_unlike(qr/999999 spots left/, 'No raw capacity shown')
      ->content_unlike(qr/2036-01-01/, 'No evergreen end date shown');
};

# The rate on both pages, as rendered text: undef when neither quotes one.
sub quoted_rates () {
    my %rate;
    for my $page ( [ landing => '/' ], [ signup => '/tenant-signup' ] ) {
        $t->get_ok( $page->[1] )->status_is(200);
        my $text = $t->tx->res->dom->all_text;
        $rate{ $page->[0] } = $text =~ /(?<![\d.])(\d+(?:\.\d+)?)%\s+(?:revenue|of processed revenue)/ ? $1 : undef;
    }
    return \%rate;
}

my $platform_admin = Test::Registry::Fixtures::create_user( $dao,
    { username => 'reglp_admin', name => 'Platform Admin', email => 'admin@reglp.test', user_type => 'admin' } );
join_tenant( $dao, $platform_admin, 'admin', 'registry' );

subtest 'landing and signup index quote the published solo rate' => sub {
    is_deeply quoted_rates(), { landing => '2.5', signup => '2.5' }, 'both pages quote Solo\'s 2.5%';

    publish_solo_version( $dao, 0.024 );

    is_deeply quoted_rates(), { landing => '2.4', signup => '2.4' }, 'both pages quote the later Solo version\'s 2.4%';
    $t->get_ok($_)->content_unlike(qr/(?<![\d.])2\.5%/, "$_ no longer says 2.5%") for '/', '/tenant-signup';
};

subtest 'no template hard codes the rate' => sub {
    for my $file ( map { Mojo::Home->new->child( 'templates', $_ )->list_tree->grep(qr/\.html\.ep$/)->each }
                   qw( registry-storefront tenant-signup ) ) {
        unlike $file->slurp, qr/(?<![\d.])2\.5%/, "$file quotes no literal 2.5%";
    }
};

# Last: it leaves registry with no platform offer, which the database refuses
# outside replica mode.
subtest 'no published offer quotes no rate' => sub {
    my $db = $dao->db;
    $db->query('SET session_replication_role = replica');
    $db->query(q{UPDATE registry.offer_versions SET superseded_at = now()
                  WHERE id IN (SELECT id FROM registry.offer_versions WHERE superseded_at IS NULL)
                    AND id IN (SELECT offer_version_id FROM registry.offer_version_payment_plans
                                WHERE kind = 'percentage_of_sales' AND fraction > 0)});
    $db->query('SET session_replication_role = DEFAULT');

    is_deeply quoted_rates(), { landing => undef, signup => undef }, 'neither page quotes a rate';
    $t->get_ok($_)->content_unlike(qr/(?<![\d.])(?:0|2\.5)%/, "$_ says neither 0% nor 2.5%") for '/', '/tenant-signup';
};

done_testing;
