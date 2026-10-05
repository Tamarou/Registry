#!/usr/bin/env perl
# ABOUTME: "Is this Alex" becomes a question the app can ask, and the job queue is behind it.
# ABOUTME: Platform-ness is being the primary user of the platform tenant, not a user_type.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use experimental 'signatures';
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( authenticate_as );
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Mojo::File;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

# The platform tenant and its primary user: the only person in the system who is
# Alex. Created the way create-default-pricing-relationships.sql does, because
# that migration is where the notion already lives.
my $platform = Registry::DAO::Tenant->platform($db);
ok $platform, 'the platform tenant is a thing the code can name';

# Alex is whoever the platform tenant's primary user already is.
# create-default-pricing-relationships.sql creates exactly one when the schema
# is built, so inventing a second here would test a fixture rather than the
# install -- and would have hidden that primary_user returns the first of
# however many is_primary rows exist.
my $alex = $platform->primary_user($db);
ok $alex, 'the platform tenant came with its owner';

# A tenant admin: every bit as much an 'admin' by user_type, and not Alex.
my $morgan = Registry::DAO::User->create( $db, {
    username => 'morgan', name => 'Morgan', user_type => 'admin',
    email => 'morgan@studio.test',
} );
my $studio = Test::Registry::Fixtures::create_tenant( $db, {
    name => 'Morgan Studio', slug => 'morgan_studio',
} );
$studio->add_user( $db, $morgan, 1 );

subtest 'the platform tenant has one owner, and the DAO can say who' => sub {
    ok Registry::DAO::Tenant->is_platform_admin( $db, $alex->id ),
        'so he is the platform admin';
    ok !Registry::DAO::Tenant->is_platform_admin( $db, $morgan->id ),
        'and a tenant admin is not, despite being an admin';
    ok !Registry::DAO::Tenant->is_platform_admin( $db, undef ),
        'nor is nobody';
};

subtest 'the job queue is not served to an anonymous visitor' => sub {
    my $t = Test::Registry::Mojo->new('Registry');
    $t->app->helper( dao => sub { $dao } );

    $t->get_ok('/platform/jobs')->status_isnt( 200,
        'not served without signing in' );
};

subtest 'nor to a tenant admin' => sub {
    # The distinction that matters: Morgan runs a studio and is an 'admin'.
    # Minion's queue is every tenant's work, so it is not his to see.
    my $t = Test::Registry::Mojo->new('Registry');
    $t->app->helper( dao => sub { $dao } );
    authenticate_as( $t, $morgan );

    $t->get_ok('/platform/jobs')->status_is( 403,
        'a tenant admin is refused' );
};

subtest 'and is served to Alex' => sub {
    my $t = Test::Registry::Mojo->new('Registry');
    $t->app->helper( dao => sub { $dao } );
    authenticate_as( $t, $alex );

    $t->get_ok('/platform/jobs')->status_is( 200, 'Alex gets the queue' )
      ->content_like( qr/minion|jobs/i, 'and it is the Minion dashboard' );
};

subtest 'every route the dashboard mounts is behind the guard' => sub {
    # Minion::Admin mounts six routes under the prefix it is given, and the
    # entry page being refused says nothing about the other five. A data route
    # that escaped the `under` would hand a tenant admin -- or anyone -- the
    # whole platform's job queue, arguments included.
    my $t = Test::Registry::Mojo->new('Registry');
    $t->app->helper( dao => sub { $dao } );
    authenticate_as( $t, $morgan );

    for my $path (qw( / /stats /history /jobs /locks /workers )) {
        $t->get_ok("/platform/jobs$path")
          ->status_is( 403, "a tenant admin is refused /platform/jobs$path" );
    }
};

subtest 'the dashboard assets are static, and carry no data' => sub {
    # The plugin pushes its own directory onto the app's static paths, and
    # static files bypass routes entirely -- so these are served to anyone.
    # Asserted rather than assumed: what is in there is bootstrap, d3, a logo
    # and the dashboard's own css/js. No job data, nothing tenant-specific.
    my $t = Test::Registry::Mojo->new('Registry');
    $t->app->helper( dao => sub { $dao } );

    $t->get_ok('/minion/app.css')->status_is( 200,
        'an asset is served without signing in, which is what static means' );

    # The plugin resolves this as path(__FILE__)->sibling('resources'), so the
    # directory sits beside Admin.pm -- not beside its parent, which is what my
    # first version guessed and why `ok scalar @files` is here: without it the
    # namespacing assertion below passed against an empty list.
    my $assets = Mojo::File->new( $INC{'Mojolicious/Plugin/Minion/Admin.pm'} )
        ->sibling('resources')->child('public');
    my @files = $assets->list_tree->map('to_string')->each;

    ok scalar @files, 'the asset directory is found where the plugin says';
    is scalar( grep { !m{/minion/} } @files ), 0,
        'and everything in it is namespaced under minion/, so nothing else is exposed';
};

subtest 'the tenant fleet screen is behind the same guard, and names what is broken' => sub {
    # #426 step 2. The screen exists to answer "is this customer actually
    # working" without a terminal, so the assertion that matters is that a
    # broken tenant is visible ON the page -- not merely that the page renders.
    Registry::DAO::Tenant->create( $db, {
        name => 'Never Provisioned', slug => 'never_provisioned',
    } );

    my $refused = Test::Registry::Mojo->new('Registry');
    $refused->app->helper( dao => sub { $dao } );
    authenticate_as( $refused, $morgan );
    $refused->get_ok('/platform/tenants')->status_is( 403,
        'a tenant admin cannot read the fleet' );

    my $t = Test::Registry::Mojo->new('Registry');
    $t->app->helper( dao => sub { $dao } );
    authenticate_as( $t, $alex );

    $t->get_ok('/platform/tenants')->status_is(200)
      ->content_like( qr/never_provisioned/,
          'the tenant that never provisioned is on the page' )
      ->content_like( qr/schema was never created/,
          'with the reason, rather than just a red mark' )
      ->content_like( qr/data-provisioning="broken"/,
          'and machine-readably, so a later digest can reuse it' );
};

subtest 'the revenue screen is behind the guard, and admits its gaps' => sub {
    # #426 step 3. The assertion that matters is not that a number renders --
    # it is that an unrecorded charge is declared on the page, so the total
    # reads as a floor. A screen that quietly omitted them would be the lie this
    # whole feature exists to avoid.
    my $solo = $db->query(
        q{SELECT id FROM registry.pricing_plans WHERE plan_name = 'Solo' LIMIT 1}
    )->hash;
    my $earning = Test::Registry::Fixtures::create_tenant( $db, {
        name => 'Revenue Screen Studio', slug => 'revenue_screen' } );
    $db->query( 'UPDATE registry.tenants SET platform_pricing_plan_id = ?,
                 billing_status = ? WHERE id = ?',
        $solo->{id}, 'past_due', $earning->id );

    my $payer = Registry::DAO::User->create( $db, {
        username => 'screen_payer', name => 'Payer', user_type => 'parent',
        email => 'payer@screen.test' } );
    require Registry::DAO::Payment;
    my $charged = Registry::DAO::Payment->create( $db, {
        user_id => $payer->id, amount_cents => 10000, status => 'completed',
        metadata => { tenant_slug => 'revenue_screen', enrollment_items => [] } } );
    $db->update( 'payments', { platform_fee_cents => 250 }, { id => $charged->id } );
    Registry::DAO::Payment->create( $db, {
        user_id => $payer->id, amount_cents => 50000, status => 'completed',
        metadata => { tenant_slug => 'revenue_screen', enrollment_items => [] } } );

    my $refused = Test::Registry::Mojo->new('Registry');
    $refused->app->helper( dao => sub { $dao } );
    authenticate_as( $refused, $morgan );
    $refused->get_ok('/platform/revenue')->status_is( 403,
        'a tenant admin cannot read the platform books' );

    my $t = Test::Registry::Mojo->new('Registry');
    $t->app->helper( dao => sub { $dao } );
    authenticate_as( $t, $alex );

    $t->get_ok('/platform/revenue')->status_is(200)
      ->content_like( qr/\$2\.50/, 'the recorded fee is shown as money' )
      ->content_like( qr/id="unrecorded-warning"/,
          'the unrecorded charge is declared, so the total reads as a floor' )
      ->content_like( qr/id="arrears"/, 'and the past_due tenant is surfaced' )
      ->content_like( qr/data-rate="2\.5/,
          'with the rate read from the plan row rather than a constant' );
};

done_testing;
