#!/usr/bin/env perl
# ABOUTME: Names the platform needs for itself are never handed to a tenant (#443).
# ABOUTME: www is the sharpest -- the router refuses it, so such a tenant is unreachable by construction.

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use experimental qw(defer signatures);
use Test::More import => [qw( done_testing is isnt ok like unlike subtest note )];
defer { done_testing };

use Test::Registry::DB;
use Registry::DAO::Tenant;

my $t_db = Test::Registry::DB->new;
my $dao  = $t_db->db;
my $db   = $dao->db;

subtest 'the names the platform needs for itself are reserved' => sub {
    # www is not a style choice. Registry.pm's _extract_tenant_from_subdomain
    # returns undef for it explicitly, so a tenant provisioned as www could
    # never be reached at its own URL -- an inert tenant by construction,
    # holding a name forever.
    ok Registry::DAO::Tenant->slug_is_reserved('www'),
        'www, which the tenant router refuses outright';

    # registry is the platform schema. clone_schema would be asked to build a
    # tenant on top of it.
    ok Registry::DAO::Tenant->slug_is_reserved('registry'),
        'registry, which is the platform schema itself';

    for my $name (qw( api admin app mail smtp static assets cdn
                      status help docs support billing )) {
        ok Registry::DAO::Tenant->slug_is_reserved($name),
            "$name, which the platform may need to serve from";
    }

    # Postgres system schemas. A tenant here would not merely shadow something,
    # it would fail to build at all -- loudly if we are lucky.
    ok Registry::DAO::Tenant->slug_is_reserved('public'),
        'public, which every schema search path already contains';
    ok Registry::DAO::Tenant->slug_is_reserved('pg_catalog'),
        'and the Postgres system schemas';
};

subtest 'an ordinary studio name is not reserved' => sub {
    ok !Registry::DAO::Tenant->slug_is_reserved('clay_kiln_studio'),
        'a real one is free';
    ok !Registry::DAO::Tenant->slug_is_reserved('apiary'),
        'and a name that merely starts like a reserved one is not reserved';
};

subtest 'deriving a slug never lands on a reserved name' => sub {
    # "API Studio" -> api_studio, fine. But an organisation actually called
    # "API" derives exactly the reserved word, and the derivation is where that
    # has to be caught: provision takes whatever it is handed.
    my $slug = Registry::DAO::Tenant->available_slug_for_name( $db, 'API' );
    isnt $slug, 'api', 'a name that derives a reserved slug gets a different one';
    ok !Registry::DAO::Tenant->slug_is_reserved($slug),
        'and what it gets is not reserved either';
    like $slug, qr/\A[a-z][a-z0-9_]{0,62}\z/,
        'and is still something the router can route';
    note "API -> $slug";

    my $www = Registry::DAO::Tenant->available_slug_for_name( $db, 'WWW' );
    isnt $www, 'www', 'nor does WWW';
};

subtest 'provisioning refuses a reserved slug it was handed directly' => sub {
    # available_slug_for_name only guards the DERIVED path. A caller naming a
    # slug gets the one they named -- deliberately, see its comment -- so the
    # refusal has to be at provision, which is the last point before
    # clone_schema builds the thing.
    my $err = do {
        local $@;
        eval {
            Registry::DAO::Tenant->provision( $db, {
                name => 'Reserved Probe', slug => 'www', users => [],
            } );
            1;
        };
        $@;
    };

    like $err, qr/reserved/i, 'provisioning dies naming the reason';

    my $row = $db->query(
        'SELECT 1 FROM registry.tenants WHERE slug = ?', 'www' )->hash;
    ok !$row, 'and no tenant row was created';

    my $schema = $db->query(
        'SELECT 1 FROM information_schema.schemata WHERE schema_name = ?', 'www' )->hash;
    ok !$schema, 'nor a schema';
};

$t_db->cleanup_test_database;
