use 5.42.0;
# ABOUTME: Tests base-domain-aware tenant resolution: apex domains resolve to
# ABOUTME: registry, wildcard subdomains to their tenant, with a schema-existence fallback.
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw(done_testing is ok subtest)];
defer { done_testing };

use Test::Mojo;
use Registry::DAO;
use Test::Registry::DB;
use Test::Registry::Fixtures;

my $t_db = Test::Registry::DB->new;
my $dao  = $t_db->db;
$ENV{DB_URL} = $t_db->uri;

# Configure platform base domains under which wildcard tenant subdomains live.
$ENV{REGISTRY_BASE_DOMAINS} = 'tinyartempire.com,localhost';

my $t = Test::Mojo->new('Registry');

# A real, provisioned tenant whose subdomain should resolve to it.
my $tenant = Test::Registry::Fixtures::create_tenant($dao, { name => 'Acme', slug => 'acme' });
$dao->db->query('SELECT clone_schema(dest_schema => ?)', $tenant->slug);

# Resolve $c->tenant for a given Host header (no auth -> no X-As-Tenant).
sub tenant_for ($host) {
    my $c = $t->app->build_controller;
    $c->req->headers->host($host);
    return $c->tenant;
}

subtest 'apex domain resolves to registry, not a tenant' => sub {
    is tenant_for('tinyartempire.com'), 'registry',
        'apex tinyartempire.com -> registry (FIX: was mis-resolving to tenant "tinyartempire")';
    is tenant_for('www.tinyartempire.com'), 'registry', 'www.<base> -> registry';
    is tenant_for('localhost'), 'registry', 'bare localhost -> registry';
};

subtest 'wildcard subdomain resolves to its tenant' => sub {
    is tenant_for('acme.tinyartempire.com'), 'acme', '<slug>.<base> -> slug';
    is tenant_for('acme.localhost'), 'acme', '<slug>.localhost -> slug (test convention)';
};

subtest 'custom domains and IPs do not extract a subdomain' => sub {
    # Not under any configured base -> subdomain extraction returns nothing;
    # falls through to the custom-domain table (none here) -> registry.
    is tenant_for('some-custom-domain.example'), 'registry',
        'host under no base -> registry (custom-domain table empty)';
    is tenant_for('127.0.0.1'), 'registry', 'IP -> registry';
};

subtest 'defensive fallback: resolved slug with no schema -> registry' => sub {
    # 'ghost' is a syntactically valid slug under the base but has no schema.
    is tenant_for('ghost.tinyartempire.com'), 'registry',
        'subdomain for a non-existent schema falls back to registry (no 500)';
};

subtest 'integration: apex host renders, does not 500 (the prod regression)' => sub {
    # GET / on the platform apex must render the registry storefront, not 500
    # with "relation \"workflows\" does not exist".
    $t->get_ok('/' => { Host => 'tinyartempire.com' })
      ->status_isnt(500);
};
