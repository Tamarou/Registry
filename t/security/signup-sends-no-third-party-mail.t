#!/usr/bin/env perl
# ABOUTME: An anonymous signup form must not mail addresses typed into it by whoever filled it in.
# ABOUTME: Delivery became real (Postmark) after #289 predicted this exact thing would (#438).

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use experimental qw(defer signatures);
use Test::More import => [qw( done_testing is ok like cmp_ok subtest diag )];
defer { done_testing };

use Email::Sender::Simple;
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Helpers qw(authenticate_as);
use Registry::DAO::Tenant;
use Registry::DAO::User;

my $t_db = Test::Registry::DB->new;
my $dao  = $t_db->db;
my $db   = $dao->db;
$ENV{DB_URL} = $t_db->uri;

$dao->import_workflows(['workflows/tenant-signup.yml']);

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper( dao => sub { $dao } );
$dao->current_tenant('registry');

my $transport = Email::Sender::Simple->default_transport;

my $victim = 'someone.who.never.asked@example.test';
my $slug;

subtest 'a signup naming a stranger sends them nothing' => sub {
    $transport->clear_deliveries;

    $t->post_ok('/tenant-signup')->status_is(302);
    my $url = $t->tx->res->headers->location;
    $t->get_ok($url)->status_is(200);

    $t->post_ok( $url => form => {
        name => 'Relay Test Studio', billing_email => 'owner@relay.example',
    } )->status_is(302);
    $url = $t->tx->res->headers->location;
    $t->get_ok($url)->status_is(200);

    # The team-member fields are the outbound primitive: an anonymous caller
    # names any address and the platform mails it, from our sending domain,
    # carrying a working magic link into a tenant they never asked to join.
    $t->post_ok( $url => form => {
        admin_name                    => 'Relay Owner',
        admin_email                   => 'owner@relay.example',
        admin_username                => 'relayowner',
        admin_user_type               => 'admin',
        'team_members[0][name]'       => 'Innocent Bystander',
        'team_members[0][email]'      => $victim,
        'team_members[0][user_type]'  => 'staff',
    } )->status_is(302);

    my $review = $t->tx->res->headers->location;
    $t->get_ok($review)->status_is(200);
    $t->post_ok( $review => form => { terms_accepted => 1 } )->status_is(302);

    my $row = $db->query(
        'SELECT slug FROM registry.tenants WHERE name = ?', 'Relay Test Studio' )->hash;
    ok $row, 'the tenant was provisioned';
    $slug = $row->{slug};

    my @sent = $transport->deliveries;
    is scalar(@sent), 0, 'the anonymous signup sent no email at all'
        or diag 'recipients: ' . join( ', ',
            map { join ',', @{ $_->{successes} // [] } } @sent );
};

subtest 'the person exists, and the screen can tell they have not been invited' => sub {
    my $tenant_dao = Registry::DAO->new( url => $dao->url, schema => $slug );

    # The username _provision_tenant derives from the address: local part with
    # every non-alphanumeric removed.
    my ($person) = Registry::DAO::User->find( $tenant_dao->db, { username => "someonewhoneverasked" } );
    ok $person, 'the team member was still created'
        or return;
    ok $person->invite_pending,
        'and is marked as not yet invited'
        or diag 'invite_pending is not persisted, so "not invited" looks like "invited"';
};

subtest 'a signed-in admin can send it, and that clears the flag' => sub {
    my $tenant_dao = Registry::DAO->new( url => $dao->url, schema => $slug );

    my $admin = Registry::DAO::User->find( $tenant_dao->db, { username => 'relayowner' } );
    ok $admin, 'the owner account exists' or return;

    my $person = Registry::DAO::User->find( $tenant_dao->db, { username => "someonewhoneverasked" } )
        or return;

    my $tenant = Registry::DAO::Tenant->find( $db, { slug => $slug } );
    ok $tenant, 'the tenant row resolves' or return;

    $transport->clear_deliveries;
    ok $tenant->invite_user( $db, $person, 'Relay Owner' ),
        'the invitation sends';

    my @sent = $transport->deliveries;
    cmp_ok scalar(@sent), '>=', 1, 'and an email actually went out';
    like join( ' ', map { join ',', @{ $_->{successes} // [] } } @sent ),
        qr/\Q$victim\E/,
        'to the person being invited';

    my $after = Registry::DAO::User->find( $tenant_dao->db, { username => "someonewhoneverasked" } );
    ok !$after->invite_pending, 'and the pending flag is cleared';
};

$t_db->cleanup_test_database;
