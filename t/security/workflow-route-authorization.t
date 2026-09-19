#!/usr/bin/env perl
# ABOUTME: Tests that admin-surface workflow slugs refuse anonymous visitors at the
# ABOUTME: /:workflow catch-all, while the acquisition funnels stay anonymous.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;

use Registry::DAO qw(Workflow);
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Test::Registry::Helpers qw(authenticate_as);
use Mojo::Home;
use YAML::XS qw(Load);

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

# Import every workflow into registry first: provision() copies whatever it
# finds there into the new tenant's schema.
my @files = Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;
for my $file (@files) {
    next if Load($file->slurp)->{draft};
    Workflow->from_yaml($dao, $file->slurp);
}

# A real tenant with a real schema, so `Host: guardtest.localhost` resolves to
# it rather than degrading to registry.
Registry::DAO::Tenant->provision($dao->db, {
    name  => 'Guard Test Studio',
    slug  => 'guardtest',
    users => [],
});

my $TENANT_HOST = 'guardtest.localhost';

my $t = Test::Registry::Mojo->new('Registry');
$t->ua->max_redirects(0);    # we are asserting on the redirect itself

my $UUID = qr/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/;

# ============================================================
# Direction 1: admin surfaces refuse anonymous visitors
# ============================================================

subtest 'anonymous admin-dashboard is refused on the registry host' => sub {
    $t->get_ok('/admin-dashboard')
      ->status_is(302, 'not served to an anonymous visitor')
      ->header_like( Location => qr{^/auth/login}, 'sent to the login page' );
};

subtest 'anonymous admin-dashboard is refused on a tenant host' => sub {
    # The guard has to fire before the dashboard step runs: on a tenant host
    # this used to render the dashboard shell to a stranger.
    $t->get_ok( '/admin-dashboard' => { Host => $TENANT_HOST } )
      ->status_is(302, 'not served to an anonymous visitor')
      ->header_like( Location => qr{^/auth/login}, 'sent to the login page' );
};

subtest 'anonymous location-management is refused on a tenant host' => sub {
    # location-management writes tenant-owned configuration; reaching its form
    # anonymously is what makes the CSRF token the only thing standing between
    # a stranger and a write.
    $t->get_ok( '/location-management' => { Host => $TENANT_HOST } )
      ->status_is(302, 'not served to an anonymous visitor')
      ->header_like( Location => qr{^/auth/login}, 'sent to the login page' );
};

# ============================================================
# Direction 2: the acquisition funnels stay anonymous
#
# This is the half that matters. tenant-signup onboards a prospect who has no
# account, and summer-camp-registration onboards a parent who creates one
# partway through; a guard broad enough to catch either has cost more than the
# bug it fixed. Each is walked past its landing page so that a run really
# advances, not merely renders.
# ============================================================

subtest 'tenant-signup is anonymous on the registry host, and advances' => sub {
    # tenant-signup is the PLATFORM funnel -- Tenant->provision deliberately
    # does not copy it into tenant schemas -- so the registry host is where it
    # has to work end to end.
    $t->get_ok('/tenant-signup')
      ->status_is(200, 'served to an anonymous prospect')
      ->content_like( qr/Let's Build Your Empire/,
        'the signup landing rendered, not the login page' )
      ->content_unlike( qr/Send Magic Link/, 'not the login page' );

    $t->post_ok('/tenant-signup')
      ->status_is( 302, 'anonymous POST starts a run' )
      ->header_like( Location => qr{^/tenant-signup/$UUID/profile$},
        'the run advanced to the profile step' );
};

subtest 'tenant-signup is not redirected to login on a tenant host' => sub {
    $t->get_ok( '/tenant-signup' => { Host => $TENANT_HOST } )
      ->status_is(200, 'served to an anonymous prospect')
      ->content_like( qr/Let's Build Your Empire/, 'the signup landing rendered' );
};

subtest 'summer-camp-registration is anonymous on a tenant host, and advances' => sub {
    $t->get_ok( '/summer-camp-registration' => { Host => $TENANT_HOST } )
      ->status_is(200, 'served to an anonymous parent')
      ->content_like( qr/Begin Registration/,
        'the registration landing rendered, not the login page' )
      ->content_unlike( qr/Send Magic Link/, 'not the login page' );

    # Past the landing and into account-check -- the step where a parent with
    # no account creates one. An anonymous visitor must be able to get here.
    $t->post_ok( '/summer-camp-registration' => { Host => $TENANT_HOST } )
      ->status_is( 302, 'anonymous POST starts a run' )
      ->header_like( Location => qr{^/summer-camp-registration/$UUID/account-check$},
        'the run advanced to the account-creation step' );
};

subtest 'a callcc out of a public storefront cannot start an admin run' => sub {
    # The callcc leg names its workflow in a different placeholder than the
    # guard on /:workflow sees, so without its own check an anonymous visitor
    # could start -- and run the first step of -- any admin workflow from the
    # storefront they are allowed to be on.
    my $tenant_dao =
      Registry::DAO->new( url => $test_db->uri, schema => 'guardtest' );
    my ($storefront) =
      $tenant_dao->find( Workflow => { slug => 'tenant-storefront' } );
    my $run = $storefront->new_run( $tenant_dao->db );

    my $runs_for = sub ($slug) {
        $tenant_dao->db->query( <<~'SQL', $slug )->array->[0];
            SELECT count(*) FROM guardtest.workflow_runs r
              JOIN guardtest.workflows w ON w.id = r.workflow_id
             WHERE w.slug = ?
            SQL
    };

    my $before = $runs_for->('location-management');

    $t->post_ok( "/tenant-storefront/@{[ $run->id ]}/callcc/location-management"
          => { Host => $TENANT_HOST } )
      ->status_is( 302, 'anonymous callcc into an admin workflow is refused' )
      ->header_like( Location => qr{^/auth/login}, 'sent to the login page' );

    is $runs_for->('location-management'), $before,
        'and no admin run was created';
};

subtest 'a callcc into the registration funnel still works anonymously' => sub {
    # The storefront's own call-to-action is a callcc; blocking it would break
    # the funnel just as thoroughly as blocking /summer-camp-registration.
    my $tenant_dao =
      Registry::DAO->new( url => $test_db->uri, schema => 'guardtest' );
    my ($storefront) =
      $tenant_dao->find( Workflow => { slug => 'tenant-storefront' } );
    my $run = $storefront->new_run( $tenant_dao->db );

    $t->post_ok(
        "/tenant-storefront/@{[ $run->id ]}/callcc/summer-camp-registration"
          => { Host => $TENANT_HOST } )
      ->status_is( 302, 'anonymous callcc into the funnel is allowed' )
      ->header_like(
        Location => qr{^/summer-camp-registration/$UUID/account-check$},
        'and lands on the account-creation step' );
};

# ============================================================
# The guard admits the people it is for. Without this, "refuse everyone" would
# satisfy every assertion above.
#
# authenticate_as installs a permanent before_dispatch hook, so it has to come
# after every anonymous case in this file.
# ============================================================

subtest 'an admin does reach location-management on a tenant host' => sub {
    my $tenant_dao =
      Registry::DAO->new( url => $test_db->uri, schema => 'guardtest' );
    my $admin = Registry::DAO::User->create( $tenant_dao->db, {
        username  => 'guard_admin',
        name      => 'Guard Admin',
        email     => 'guard_admin@example.com',
        user_type => 'admin',
    } );
    authenticate_as( $t, $admin );

    $t->get_ok( '/location-management' => { Host => $TENANT_HOST } )
      ->status_is( 200, 'served to an admin' )
      ->content_unlike( qr/Send Magic Link/, 'not the login page' );
};

done_testing;
