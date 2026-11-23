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
use Capture::Tiny qw( capture_merged );

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

subtest 'a member of both rows keeps one membership, primary if either was' => sub {
    my ( $uri, $db ) = fresh_db();
    my $deleted = registry_id($db);

    my $both = make_user( $db, 'member_of_both' );
    $db->query( q{INSERT INTO registry.tenant_users (tenant_id, user_id, is_primary) VALUES (?, ?, true)},
        $deleted, $both );
    $db->query( q{INSERT INTO registry.tenant_users (tenant_id, user_id, is_primary) VALUES (?, ?, false)},
        PLATFORM_UUID, $both );

    lives_ok { deploy($uri) } 'the change deploys despite the shared membership';

    my $rows = $db->query( q{SELECT tenant_id, is_primary FROM registry.tenant_users WHERE user_id = ?}, $both )
        ->hashes;
    is scalar @$rows, 1, 'exactly one membership remains for the user';
    is $rows->[0]{tenant_id}, PLATFORM_UUID, 'on the all-zeros row';
    ok $rows->[0]{is_primary}, 'and it is primary, because the deleted one was';
};

subtest 'the kept row value is not overwritten by the deleted row value' => sub {
    my ( $uri, $db ) = fresh_db();
    my $deleted = registry_id($db);

    $db->query( q{UPDATE registry.tenants SET canonical_domain = 'old-registry.example' WHERE id = ?}, $deleted );
    $db->query( q{UPDATE registry.tenants SET canonical_domain = 'platform.example' WHERE id = ?}, PLATFORM_UUID );

    lives_ok { deploy($uri) } 'the change deploys';

    is $db->query( q{SELECT canonical_domain FROM registry.tenants WHERE id = ?}, PLATFORM_UUID )
          ->hash->{canonical_domain}, 'platform.example',
        "the kept row's canonical domain stands";
};

subtest 'the deleted row stripe customer and subscription fill the kept row gaps' => sub {
    my ( $uri, $db ) = fresh_db();
    my $deleted = registry_id($db);
    $db->query( q{UPDATE registry.tenants SET stripe_customer_id = 'cus_old', stripe_subscription_id = 'sub_old',
                  trial_ends_at = '2026-01-01', subscription_started_at = '2025-12-01' WHERE id = ?}, $deleted );

    lives_ok { deploy($uri) } 'the change deploys';

    my $row = $db->query( q{SELECT stripe_customer_id, stripe_subscription_id, trial_ends_at::date AS t,
                                   subscription_started_at::date AS s
                              FROM registry.tenants WHERE id = ?}, PLATFORM_UUID )->hash;
    is $row->{stripe_customer_id},     'cus_old',    'the customer id is carried over';
    is $row->{stripe_subscription_id}, 'sub_old',    'the subscription id is carried over';
    is $row->{t},                      '2026-01-01', 'the trial end is carried over';
    is $row->{s},                      '2025-12-01', 'the subscription start is carried over';
};

# The deleted row was the one a login on the registry schema read, so its
# expiry is the one in force. Two different values is a choice for a person.
subtest 'a differing magic link expiry refuses the deploy' => sub {
    my ( $uri, $db ) = fresh_db();
    my $deleted = registry_id($db);
    $db->query( q{UPDATE registry.tenants SET magic_link_expiry_hours = 4 WHERE id = ?}, $deleted );

    my $err = do { local $@; eval { capture_merged { deploy($uri) }; 1 } ? '' : "$@" };
    isnt $err, '', 'the deploy refuses';
    ok $db->query( q{SELECT 1 FROM registry.tenants WHERE id = ?}, $deleted )->hash,
        'and nothing was collapsed: the deleted row is still there';
};

subtest 'no tenant_id column still holds the deleted row id' => sub {
    my ( $uri, $db ) = fresh_db();
    my $deleted = registry_id($db);

    # Something for the column sweep to move: subscription_events.tenant_id is
    # the one tenant_id column the deploy does not handle by name.
    $db->query(
        q{INSERT INTO registry.subscription_events (tenant_id, stripe_event_id, event_type, event_data)
          VALUES (?, 'evt_collapse', 'customer.subscription.updated', '{}')}, $deleted );
    my $member = make_user( $db, 'swept_member' );
    $db->query( q{INSERT INTO registry.tenant_users (tenant_id, user_id) VALUES (?, ?)}, $deleted, $member );

    lives_ok { deploy($uri) } 'the change deploys';

    # Discovered, not listed: the assertion has to cover a column added later
    # as well as the ones that exist today.
    my $columns = $db->query(
        q{SELECT c.table_name, c.column_name
            FROM information_schema.columns c
            JOIN information_schema.tables t
              ON t.table_schema = c.table_schema AND t.table_name = c.table_name
           WHERE c.table_schema = 'registry'
             AND t.table_type   = 'BASE TABLE'
             AND c.data_type    = 'uuid'
             AND c.column_name LIKE '%tenant\_id'
           ORDER BY 1, 2}
    )->hashes;
    ok scalar @$columns, 'the sweep finds tenant_id columns to look in';

    for my $col (@$columns) {
        my ( $table, $column ) = map { $db->dbh->quote_identifier($_) } @$col{qw(table_name column_name)};
        is $db->query( "SELECT count(*) FROM registry.$table WHERE $column = ?", $deleted )->array->[0], 0,
            "registry.$col->{table_name}.$col->{column_name} no longer holds the deleted id";
    }

    is $db->query(q{SELECT tenant_id FROM registry.subscription_events WHERE stripe_event_id = 'evt_collapse'})
          ->hash->{tenant_id}, PLATFORM_UUID, 'the subscription event now names the platform row';
};

# tenant_domains.domain is UNIQUE across tenants, so the two rows can never
# share a domain. What can collide is idx_tenant_domains_primary -- one primary
# domain per tenant -- when both rows have one.
subtest 'a primary domain on both rows leaves the kept row primary' => sub {
    my ( $uri, $db ) = fresh_db();
    my $deleted = registry_id($db);

    $db->query( q{INSERT INTO registry.tenant_domains (tenant_id, domain, status, is_primary)
                  VALUES (?, 'kept.example.test', 'verified', true)}, PLATFORM_UUID );
    $db->query( q{INSERT INTO registry.tenant_domains (tenant_id, domain, status, is_primary)
                  VALUES (?, 'moved.example.test', 'verified', true)}, $deleted );

    lives_ok { deploy($uri) } 'the change deploys';

    my $domains = $db->query(
        q{SELECT domain, is_primary FROM registry.tenant_domains WHERE tenant_id = ? ORDER BY domain},
        PLATFORM_UUID )->hashes;
    is_deeply $domains,
        [ { domain => 'kept.example.test', is_primary => 1 },
          { domain => 'moved.example.test', is_primary => 0 } ],
        "both domains now belong to the kept row, and only the kept row's primary is primary";
};

subtest 'the deploy succeeds with no dependants on the deleted row' => sub {
    my ( $uri, $db ) = fresh_db();
    my $deleted = registry_id($db);

    # The seed's registry row normally carries nothing; make sure of it, so this
    # scenario does not depend on what an earlier change happened to seed.
    for my $table (qw( tenant_users tenant_profiles tenant_domains subscription_events )) {
        $db->query( "DELETE FROM registry.$table WHERE tenant_id = ?", $deleted );
    }
    $db->query( q{DELETE FROM registry.pricing_relationships WHERE provider_id = ?}, $deleted );

    lives_ok { deploy($uri) } 'the change deploys';

    my $rows = $db->query(q{SELECT id FROM registry.tenants WHERE slug = 'registry'})->hashes;
    is scalar @$rows, 1, 'exactly one tenant row has slug registry';
    is $rows->[0]{id}, PLATFORM_UUID, 'and it is the all-zeros row';
};

done_testing;
