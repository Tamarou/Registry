#!/usr/bin/env perl
# ABOUTME: Anonymous signup must not be an unbounded schema-clone and subdomain-claim machine.
# ABOUTME: The card was the only thing bounding it (#362); dropping it (#365) left nothing (#438).

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use experimental qw(defer signatures);
use Test::More import => [qw( done_testing is isnt ok like unlike cmp_ok subtest diag )];
defer { done_testing };

use Test::Registry::Mojo;
use Test::Registry::DB;
use Registry::DAO::WorkflowSteps::TenantPayment;

my $t_db = Test::Registry::DB->new;
my $dao  = $t_db->db;
my $db   = $dao->db;
$ENV{DB_URL} = $t_db->uri;

$dao->import_workflows(['workflows/tenant-signup.yml']);

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper( dao => sub { $dao } );
$dao->current_tenant('registry');

my $LIMIT = Registry::DAO::WorkflowSteps::TenantPayment->PROVISIONINGS_PER_HOUR;
cmp_ok $LIMIT, '>', 0, "there is an hourly provisioning limit ($LIMIT)";

# Walks the whole funnel over HTTP and returns the review URL.
#
# %extra goes on the USERS step, not the review step. Run data is written from
# step RESULTS, and the plain steps echo their form data back -- so the users
# POST is the one that can put a key into the run for the commit to read. The
# review step returns only its own keys, which is why planting there proves
# nothing.
sub sign_up ( $name, %extra ) {
    $t->post_ok('/tenant-signup')->status_is(302);
    my $url = $t->tx->res->headers->location;
    $t->get_ok($url)->status_is(200);

    $t->post_ok( $url => form => {
        name => $name, billing_email => 'billing@rate.example',
    } )->status_is(302);
    $url = $t->tx->res->headers->location;
    $t->get_ok($url)->status_is(200);

    my $user = lc( $name =~ s/\W+/_/gr );
    $t->post_ok( $url => form => {
        admin_name      => "Admin $name",
        admin_email     => "$user\@rate.example",
        admin_username  => $user,
        admin_user_type => 'admin',
        %extra,
    } )->status_is(302);
    my $review = $t->tx->res->headers->location;
    $t->get_ok($review)->status_is(200);

    $t->post_ok( $review => form => { terms_accepted => 1 } );
    return $review;
}

sub tenant_row ($name) {
    return $db->query(
        # host(), not ::text: this Postgres renders an inet with its mask, so
        # ::text gives 127.0.0.1/32 and host() gives the address on its own.
        'SELECT slug, host(created_from_ip) AS ip FROM registry.tenants WHERE name = ?',
        $name )->hash;
}

# Test::Mojo connects over loopback, so this is the address every signup below
# is really coming from. Asserted against rather than merely "something", because
# "not the planted value" is satisfied by garbage too.
my $REAL_IP = '127.0.0.1';

subtest 'a provisioned tenant records the address it came from' => sub {
    sign_up('Rate Recorded Studio');

    my $row = tenant_row('Rate Recorded Studio');
    ok $row, 'the tenant was provisioned';
    is $row->{ip}, $REAL_IP, "and its address was recorded ($REAL_IP)"
        or diag 'nothing records created_from_ip, so nothing can be rate limited';
};

# The whole mechanism turns on the address being the server's, not the caller's.
subtest 'the address cannot be chosen by the client' => sub {
    my $planted = '203.0.113.9';

    # Both spellings: the flat key, and the bracketed form that used to survive
    # _apply_server_owned_data and get rebuilt downstream by expand_form_params.
    sign_up( 'Rate Planted Studio',
        __remote_address         => $planted,
        '__remote_address[!=]'   => $planted,
    );

    my $row = tenant_row('Rate Planted Studio');
    ok $row, 'the tenant was provisioned';
    is $row->{ip}, $REAL_IP,
        'the connection address is recorded, not the one the client named';
};

subtest 'provisioning is refused past the hourly limit' => sub {
    # Test::Mojo connects from the loopback address, which is what the earlier
    # subtests recorded, so fill the window on that one.
    my $ip = tenant_row('Rate Recorded Studio')->{ip};
    ok $ip, "filling the window for $ip";

    my $already = $db->query(
        q{SELECT count(*) AS n FROM registry.tenants
           WHERE created_from_ip = ? AND created_at > now() - interval '1 hour'},
        $ip )->hash->{n};

    # Seeded directly, which is legitimate here: created_from_ip is written by
    # shipped code -- the subtest above proves it -- so this is standing in for
    # earlier signups, not for a state the product cannot reach.
    for my $i ( $already .. $LIMIT ) {
        $db->query(
            'INSERT INTO registry.tenants (name, slug, created_from_ip) VALUES (?, ?, ?)',
            "Filler $i", "filler_$i", $ip );
    }

    my $review = sign_up('Rate Refused Studio');

    ok !tenant_row('Rate Refused Studio'),
        'no tenant is created once the window is full';

    # A refused step flashes its errors and redirects back, so the message is on
    # the page the applicant lands on rather than in the POST response.
    $t->status_is(302);
    $t->get_ok($review)->status_is(200)
      ->content_like( qr/Too many organizations/i,
          'and the applicant is told why, rather than seeing a dead button' );
};

$t_db->cleanup_test_database;
