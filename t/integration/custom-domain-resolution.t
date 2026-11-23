#!/usr/bin/env perl
# ABOUTME: Integration tests for canonical domain redirect and custom domain
# ABOUTME: tenant resolution. Validates 301 redirect, path preservation, and fallback.
use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Mojo;
use Test::Registry::DB;
use Test::Registry::Fixtures;

my $tdb = Test::Registry::DB->new;
my $dao = $tdb->db;
$ENV{DB_URL} = $tdb->uri;

# Create a tenant with a canonical domain set
my $tenant = Test::Registry::Fixtures::create_tenant($dao->db, {
    name => 'Dance Stars',
    slug => 'dance_stars',
});
$dao->db->update('tenants',
    { canonical_domain => 'dance-stars.com' },
    { id => $tenant->id }
);

my $t = Test::Mojo->new('Registry');

subtest 'Request on non-canonical domain redirects to canonical' => sub {
    # Simulate request arriving on the subdomain when canonical domain is set.
    # Host comparison is case-insensitive (domains are case-insensitive per RFC 1035).
    $t->get_ok('/auth/login' => { Host => 'dance_stars.localhost' })
      ->status_is(301, 'Non-canonical domain returns 301')
      ->header_like(Location => qr{^https?://dance-stars\.com/auth/login},
        'Redirects to canonical domain with same path');
};

subtest 'Request on canonical domain does not redirect' => sub {
    $t->get_ok('/auth/login' => { Host => 'dance-stars.com' })
      ->status_isnt(301, 'Canonical domain does not redirect');
};

subtest 'Redirect preserves query string' => sub {
    $t->get_ok('/workflow/enrollment?session=abc' => { Host => 'dance_stars.localhost' })
      ->status_is(301)
      ->header_like(Location => qr{dance-stars\.com/workflow/enrollment\?session=abc},
        'Query string preserved in redirect');
};

subtest 'Tenant without canonical domain does not redirect' => sub {
    my $plain = Test::Registry::Fixtures::create_tenant($dao->db, {
        name => 'Plain Tenant',
        slug => 'plain_tenant',
    });
    $t->get_ok('/auth/login' => { Host => 'plain_tenant.localhost' })
      ->status_isnt(301, 'No redirect when canonical_domain is not set');
};

subtest 'Webhooks are not redirected' => sub {
    $t->post_ok('/webhooks/stripe' => { Host => 'dance_stars.localhost' },
        json => { type => 'test' })
      ->status_isnt(301, 'Webhook requests skip canonical redirect');
};

subtest 'Static assets are not redirected' => sub {
    $t->get_ok('/assets/app.css' => { Host => 'dance_stars.localhost' })
      ->status_isnt(301, 'Static asset requests skip canonical redirect');
};

subtest 'Redirect loop is prevented when host already matches canonical' => sub {
    # Even if canonical_domain contains the same value as the request host,
    # there must be no redirect (guards against misconfigured duplicate entries).
    $t->get_ok('/auth/login' => { Host => 'dance-stars.com' })
      ->status_isnt(301, 'No redirect loop when host equals canonical_domain');
};

subtest 'Custom domain resolves to correct tenant' => sub {
    # Insert a verified domain for the dance_stars tenant.
    # The domain uses a www. prefix so _extract_tenant_from_subdomain returns
    # nothing and the custom domain lookup runs.
    # Once the lookup resolves dance_stars (which has canonical_domain set),
    # a request on www.dance-stars.com triggers the canonical redirect to
    # dance-stars.com, confirming the correct tenant was resolved.
    $dao->db->insert('tenant_domains', {
        tenant_id  => $tenant->id,
        domain     => 'www.dance-stars.com',
        status     => 'verified',
    });

    $t->get_ok('/auth/login' => { Host => 'www.dance-stars.com' })
      ->status_is(301, 'Verified custom domain resolves to tenant, triggering canonical redirect');
};

subtest 'Unverified custom domain does not resolve to tenant' => sub {
    # An unverified domain should NOT be resolved to the tenant. Without
    # resolution, the request falls back to the registry schema which has no
    # canonical_domain, so no redirect occurs (200).
    $dao->db->insert('tenant_domains', {
        tenant_id  => $tenant->id,
        domain     => 'www.pending-dance.com',
        status     => 'pending',
    });

    $t->get_ok('/auth/login' => { Host => 'www.pending-dance.com' })
      ->status_isnt(301, 'Pending domain does not resolve to tenant (no canonical redirect)');
};

# The platform tenant is redirected by the same rule as every tenant. The bare
# host resolves to it.
sub platform_canonical ($domain) {
    $dao->db->update( 'registry.tenants', { canonical_domain => $domain }, { slug => 'registry' } );
}

subtest 'the platform tenant without a canonical domain is not redirected' => sub {
    platform_canonical(undef);
    $t->get_ok( '/auth/login' => { Host => 'localhost' } )
      ->status_isnt( 301, 'no canonical domain, no redirect' );
};

subtest 'the platform tenant with a canonical domain is redirected to it' => sub {
    platform_canonical('platform-home.example');
    $t->get_ok( '/auth/login' => { Host => 'localhost' } )
      ->status_is( 301, 'the platform on another host is redirected' )
      ->header_like( Location => qr{^https?://platform-home\.example/auth/login},
        'to its canonical domain, path kept' );
};

subtest 'a request on the platform canonical domain is not redirected' => sub {
    platform_canonical('registry.example');
    $t->get_ok( '/auth/login' => { Host => 'registry.example' } )
      ->status_isnt( 301, 'already there: no redirect, so no loop' );
};

subtest 'the platform canonical domain never captures another tenant host' => sub {
    platform_canonical('platform-home.example');
    $t->get_ok( '/auth/login' => { Host => 'dance_stars.localhost' } )
      ->status_is(301)
      ->header_like( Location => qr{^https?://dance-stars\.com/},
        "a tenant with its own canonical domain goes to its own" );
    $t->get_ok( '/auth/login' => { Host => 'plain_tenant.localhost' } )
      ->status_isnt( 301, 'a tenant with none is not sent to the platform' );
    platform_canonical(undef);
};

done_testing();
