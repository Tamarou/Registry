#!/usr/bin/env perl
# ABOUTME: The platform's two tenant rows, registry and the all-zeros registry-platform, become one.
# ABOUTME: Plants dependants on the row being deleted, deploys the change, and asserts where they went.

use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use App::Sqitch;
use Test::PostgreSQL;
use Mojo::Pg;
use Mojo::URL;

use constant PLATFORM_UUID => '00000000-0000-0000-0000-000000000000';
use constant CHANGE        => 'collapse-platform-tenant';

my $pgsql = Test::PostgreSQL->new() or plan skip_all => $Test::PostgreSQL::errstr;
my $base_uri = $pgsql->uri;

# Deploy once to this change's parent, then give every subtest its own copy of
# that database: each scenario plants a different set of fixtures on the row the
# change deletes, and the change cannot be reverted back to two rows with them
# intact.  sqitch's own registry lives in the same database, so a template copy
# carries the deploy state with it.  See retire-registry-plus-plan.t for why the
# change is named with '^' rather than its predecessor.
lives_ok { App::Sqitch->new->run( 'sqitch', 'deploy', '-t', $base_uri, '--to', CHANGE . '^' ) }
    'deploy to the parent change succeeds';

my $copies = 0;

# A fresh database at the parent change, and a handle on it.
sub fresh_db () {
    # CREATE DATABASE ... TEMPLATE refuses while anyone else is connected to the
    # template, so this handle connects to the maintenance database instead.
    state $postgres = do {
        my $url = Mojo::URL->new($base_uri)->path('/postgres');
        Mojo::Pg->new( $url->to_unsafe_string )->db;
    };
    my $name     = 'collapse_' . ++$copies;
    my $template = $postgres->dbh->quote_identifier(
        Mojo::URL->new($base_uri)->path->parts->[0] );
    $postgres->query("CREATE DATABASE $name TEMPLATE $template");

    my $uri = Mojo::URL->new($base_uri)->path("/$name")->to_unsafe_string;
    return ( $uri, Mojo::Pg->new($uri)->db );
}

sub deploy ($uri) {
    App::Sqitch->new->run( 'sqitch', 'deploy', '-t', $uri, '--to', CHANGE );
}

sub registry_id ($db) {
    return $db->query(q{SELECT id FROM registry.tenants WHERE slug = 'registry'})->hash->{id};
}

sub make_user ($db, $name) {
    return $db->query(
        q{INSERT INTO registry.users (username, user_type) VALUES (?, 'admin') RETURNING id},
        $name
    )->hash->{id};
}

subtest 'the two platform rows collapse into one registry row' => sub {
    my ( $uri, $db ) = fresh_db();
    my $deleted = registry_id($db);
    isnt $deleted, PLATFORM_UUID, 'before the change, registry is a different row from the platform';

    my $member = make_user( $db, 'registry_row_member' );
    $db->query( q{INSERT INTO registry.tenant_users (tenant_id, user_id, is_primary) VALUES (?, ?, true)},
        $deleted, $member );
    $db->query( q{INSERT INTO registry.tenant_profiles (tenant_id, description) VALUES (?, 'the system row')},
        $deleted );
    $db->query(
        q{INSERT INTO registry.tenant_domains (tenant_id, domain, status) VALUES (?, 'platform.example', 'verified')},
        $deleted );
    $db->query( q{UPDATE registry.tenants SET canonical_domain = 'registry.example' WHERE id = ?}, $deleted );

    lives_ok { deploy($uri) } 'the change deploys';

    my $rows = $db->query(q{SELECT id FROM registry.tenants WHERE slug = 'registry'})->hashes;
    is scalar @$rows, 1, 'exactly one tenant row has slug registry';
    is $rows->[0]{id}, PLATFORM_UUID, 'and it is the all-zeros row';
    is $db->query(q{SELECT count(*) FROM registry.tenants WHERE slug = 'registry-platform'})->array->[0], 0,
        'no row has slug registry-platform';
    is $db->query(q{SELECT count(*) FROM registry.tenants WHERE id = ?}, $deleted)->array->[0], 0,
        'the old registry row is gone';

    is $db->query( q{SELECT tenant_id FROM registry.tenant_users WHERE user_id = ?}, $member )->hash->{tenant_id},
        PLATFORM_UUID, 'the membership moved to the all-zeros row';
    is $db->query(q{SELECT tenant_id FROM registry.tenant_profiles WHERE description = 'the system row'})
          ->hash->{tenant_id}, PLATFORM_UUID, 'the profile moved';
    is $db->query(q{SELECT tenant_id FROM registry.tenant_domains WHERE domain = 'platform.example'})
          ->hash->{tenant_id}, PLATFORM_UUID, 'the domain moved rather than cascading away';
    is $db->query( q{SELECT canonical_domain FROM registry.tenants WHERE id = ?}, PLATFORM_UUID )
          ->hash->{canonical_domain}, 'registry.example', 'the canonical domain moved';
};

done_testing;
