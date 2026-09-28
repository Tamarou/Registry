#!/usr/bin/env perl
# ABOUTME: Drives Connect onboarding against the real Stripe test API, end to end from the admin screen.
# ABOUTME: Requires STRIPE_SECRET_KEY (sk_test_); skips entirely without one.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use experimental qw(signatures);
use Test::More;
use Test::Registry::StripeConnect;
use Test::Registry::DB;
use Test::Registry::Mojo;
use Test::Registry::Helpers qw(authenticate_as);

use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::Service::Stripe;

plan skip_all => 'STRIPE_SECRET_KEY (sk_test_) not set'
    unless Test::Registry::StripeConnect::available();

# The onboarding links Stripe mints point back at the tenant's own host, and
# that host is built from this list. Pin it rather than inherit a shell's.
local $ENV{REGISTRY_BASE_DOMAINS} = 'tinyartempire.com,localhost';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper( dao => sub { $dao } );

my $admin = $dao->create( User => { username => 'live_connect_admin', user_type => 'admin' } );
authenticate_as( $t, $admin );

# Accounts created here are real objects in Stripe's test mode and are deleted
# at the end. Collected as we go so a mid-test failure still cleans up.
my @created;
END {
    local $?;
    return unless @created;
    my $stripe = eval { Registry::Service::Stripe->from_env } or return;
    for my $id (@created) {
        eval { $stripe->_await( $stripe->_request_async( 'DELETE', "accounts/$id" ) ); 1 }
            or warn "# could not delete $id: $@";
    }
    warn "# connect-onboarding cleanup: deleted (" . join( ', ', @created ) . ")\n";
}

subtest 'the service can create an account and a hosted onboarding link' => sub {
    my $stripe = Registry::Service::Stripe->from_env;

    my $account = $stripe->create_account({
        type                     => 'standard',
        'business_profile[name]' => 'Service Level Studio',
        'metadata[purpose]'      => 'registry-test-suite',
    });
    like $account->{id}, qr/^acct_/, 'Stripe returns a connected account id';
    push @created, $account->{id};

    my $link = $stripe->create_account_link({
        account     => $account->{id},
        type        => 'account_onboarding',
        refresh_url => 'https://example.test/admin/billing/refresh',
        return_url  => 'https://example.test/admin/billing/return',
    });
    like $link->{url}, qr{^https://connect\.stripe\.com/},
        'and a hosted onboarding URL to send the tenant to';

    # Not ready yet, and the product must not pretend otherwise: an account
    # exists the moment it is created, long before Stripe approves it.
    my $fetched = $stripe->retrieve_account( $account->{id} );
    ok !$fetched->{charges_enabled},
        'a brand new account cannot take charges';
};

# ---------------------------------------------------------------------------
# The path no test had: a tenant going from "cannot take money" to having a
# Connect account, by pressing the button, with nothing writing the column by
# hand.
# ---------------------------------------------------------------------------
subtest 'pressing the button on the admin screen creates and persists the account' => sub {
    my $before = Registry::DAO::Tenant->find( $dao->db, { slug => 'registry' } );
    is $before->stripe_connect_account_id, undef,
        'the tenant starts with no connected account';
    ok !$before->stripe_connect_ready, 'and cannot take money';

    $t->post_ok('/admin/billing/connect')->status_is(302);

    my $location = $t->tx->res->headers->location;
    like $location, qr{^https://connect\.stripe\.com/},
        'the tenant is redirected to Stripe to finish onboarding';

    my $after = Registry::DAO::Tenant->find( $dao->db, { slug => 'registry' } );
    like $after->stripe_connect_account_id, qr/^acct_/,
        'and the account id is persisted before the redirect'
        or return;
    push @created, $after->stripe_connect_account_id;

    # Still not ready. The account exists; Stripe has approved nothing.
    ok !$after->stripe_connect_ready,
        'creating the account is not the same as being able to charge';

    # Pressing it again must not mint a second account: the first one exists at
    # Stripe, the webhook matches tenants by its id, and an orphan would leave
    # the tenant's money routed to an account nothing reads.
    my $first_id = $after->stripe_connect_account_id;
    $t->post_ok('/admin/billing/connect')->status_is(302);
    my $again = Registry::DAO::Tenant->find( $dao->db, { slug => 'registry' } );
    is $again->stripe_connect_account_id, $first_id,
        'a second attempt reuses the account rather than orphaning it';
};

subtest 'the return URL reads the real account rather than assuming' => sub {
    my $tenant = Registry::DAO::Tenant->find( $dao->db, { slug => 'registry' } );
    my $account_id = $tenant->stripe_connect_account_id
        or plan skip_all => 'no account was created';

    $t->get_ok('/admin/billing/return')->status_is(200);

    my $after = Registry::DAO::Tenant->find( $dao->db, { slug => 'registry' } );
    my $live  = Registry::Service::Stripe->from_env->retrieve_account($account_id);

    is $after->stripe_charges_enabled   ? 1 : 0, $live->{charges_enabled}   ? 1 : 0,
        'charges_enabled mirrors what Stripe says';
    is $after->stripe_details_submitted ? 1 : 0, $live->{details_submitted} ? 1 : 0,
        'details_submitted likewise';

    # The screen must say the true thing about an unfinished account.
    $t->content_like(qr/Stripe still needs something from you/i,
        'and the screen reports it as unfinished, not ready');
};

$test_db->cleanup_test_database;
done_testing;
