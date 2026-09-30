#!/usr/bin/env perl
# ABOUTME: A tenant nobody has ever signed into is identifiable, so a held subdomain can be reclaimed.
# ABOUTME: Reported, never reaped: freeing a slug drops a schema, and a wrong predicate deletes a studio.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use experimental qw(defer signatures);
use Test::More import => [qw( done_testing is ok like subtest note )];
defer { done_testing };

use Test::Registry::DB;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::MagicLinkToken;

my $t_db = Test::Registry::DB->new;
my $dao  = $t_db->db;
my $db   = $dao->db;

sub tenant_aged ( $slug, $days ) {
    my $admin = $dao->create( User => {
        username => "${slug}_admin", user_type => 'admin',
        email => "$slug\@aged.example", name => ucfirst $slug,
    } );
    my $tenant = Registry::DAO::Tenant->provision( $db, {
        name => ucfirst($slug) . ' Studio', slug => $slug, users => [$admin],
    } );
    $db->query(
        "UPDATE registry.tenants SET created_at = now() - (\$1 || ' days')::interval WHERE slug = \$2",
        $days, $slug );
    return $tenant;
}

sub slugs_of ( $result ) { return [ sort map { $_->{slug} } @{ $result->{tenants} } ] }

subtest 'a tenant nobody has signed into is inert' => sub {
    tenant_aged( 'never_used', 60 );

    my $inert = Registry::DAO::Tenant->inert( $db, older_than_days => 30 )->{tenants};
    ok scalar( grep { $_->{slug} eq 'never_used' } @$inert ),
        'it is reported';

    my ($row) = grep { $_->{slug} eq 'never_used' } @$inert;
    like $row->{reason}, qr/never signed into/, 'and why';
};

subtest 'a tenant somebody has signed into is not' => sub {
    my $tenant = tenant_aged( 'actually_used', 60 );

    # There is no password login, so the first way into any tenant is a magic
    # link -- which makes a consumed token the reliable "somebody has been here"
    # signal. A passkey needs an authenticated session first, so it cannot be the
    # first way in and cannot hide a login from this.
    my $tenant_db = $tenant->dao($db)->db;
    my ($user) = Registry::DAO::User->find( $tenant_db, { username => 'actually_used_admin' } );
    ok $user, 'the admin exists in the tenant schema' or return;

    my ( $token ) = Registry::DAO::MagicLinkToken->generate( $tenant_db,
        { user_id => $user->id, purpose => 'login', expires_in => 24 } );
    $tenant_db->query(
        'UPDATE magic_link_tokens SET consumed_at = now() WHERE id = ?', $token->id );

    my $inert = Registry::DAO::Tenant->inert( $db, older_than_days => 30 )->{tenants};
    ok !scalar( grep { $_->{slug} eq 'actually_used' } @$inert ),
        'it is not reported';
};

subtest 'a tenant created yesterday is nobody business yet' => sub {
    tenant_aged( 'brand_new', 1 );

    my $inert = Registry::DAO::Tenant->inert( $db, older_than_days => 30 )->{tenants};
    ok !scalar( grep { $_->{slug} eq 'brand_new' } @$inert ),
        'too young to be called abandoned';

    # An applicant who signed up this morning and has not opened their email yet
    # is not squatting.
    my $all = Registry::DAO::Tenant->inert( $db, older_than_days => 1 );
    ok scalar( grep { $_->{slug} eq 'brand_new' } @{ $all->{tenants} } ),
        'but the window is the callers: with a one-day window it is reported';
    note 'one-day window: ' . join ', ', @{ slugs_of($all) };
};

subtest 'the platform schema is never reported' => sub {
    my $inert = Registry::DAO::Tenant->inert( $db, older_than_days => 1 )->{tenants};
    ok !scalar( grep { $_->{slug} eq 'registry' } @$inert ),
        'registry is not a tenant anybody signs into';
};

# The point of it being a report. Nothing here deletes anything, and the test
# says so: a predicate slightly wrong in an automatic reaper would drop a live
# studio's schema, which no backup restores in a hurry.
subtest 'reporting does not reap' => sub {
    Registry::DAO::Tenant->inert( $db, older_than_days => 1 );

    for my $slug (qw( never_used actually_used brand_new )) {
        ok $db->query( 'SELECT 1 FROM registry.tenants WHERE slug = ?', $slug )->hash,
            "$slug still exists";
        ok $db->query(
            'SELECT 1 FROM information_schema.schemata WHERE schema_name = ?', $slug )->hash,
            "and so does its schema";
    }
};

$t_db->cleanup_test_database;
