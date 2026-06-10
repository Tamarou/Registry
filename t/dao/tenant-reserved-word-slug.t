# ABOUTME: Tests that Tenant->provision quotes the slug as a PostgreSQL identifier.
# ABOUTME: Ensures reserved-word slugs (e.g. "user", "order") provision without DDL syntax errors.

use 5.42.0;
use lib qw(lib t/lib);
use experimental qw(defer keyword_any);
use Test::More import => [qw(done_testing is ok subtest diag)];
defer { done_testing };

use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Test::Registry::DB;
use Test::Registry::Helpers qw(import_all_workflows);

# PostgreSQL reserved words that are valid slug values (match [a-z][a-z0-9_]*)
# but cause DDL syntax errors when interpolated unquoted into:
#   INSERT INTO <slug>.program_types (...)
#   SET search_path = <slug>, public
# quote_identifier wraps them in double-quotes, making the DDL valid.

my $t_db = Test::Registry::DB->new;
my $dao  = $t_db->db;
$ENV{DB_URL} = $t_db->uri;
my $db = $dao->db;

import_all_workflows($dao);

# "user" is a PostgreSQL reserved word.  Without identifier quoting,
# "INSERT INTO user.program_types ..." is a syntax error because PostgreSQL
# parses "user" as the USER keyword, not a schema name.
subtest 'provision succeeds for slug "user" (PostgreSQL reserved word)' => sub {
    my $admin = Registry::DAO::User->create($db, {
        username  => 'reserved_word_admin',
        user_type => 'admin',
        email     => 'reserved_word_admin@test.com',
        name      => 'Reserved Word Admin',
    });

    my $tenant;
    eval {
        $tenant = Registry::DAO::Tenant->provision($db, {
            name  => 'User Schema Tenant',
            slug  => 'user',
            users => [ $admin ],
        });
    };
    my $err = $@;

    ok !$err, "provision does not throw a DDL syntax error for slug 'user' (err: $err)"
        or diag "Error was: $err";
    ok $tenant, 'provision returned a Tenant object';
    is $tenant->slug, 'user', 'tenant slug is "user"';

    if ($tenant) {
        # Verify the schema was actually created and seeded
        my $tenant_dao = Registry::DAO->new(url => $ENV{DB_URL}, schema => $tenant->slug);
        my @slugs = map { $_->{slug} }
            $tenant_dao->db->select('workflows', ['slug'])->hashes->each;
        ok scalar @slugs > 0, 'tenant schema has workflows copied into it';
    }
};

# "order" is another PostgreSQL reserved word used in ORDER BY.
subtest 'provision succeeds for slug "order" (PostgreSQL reserved word)' => sub {
    my $admin2 = Registry::DAO::User->create($db, {
        username  => 'order_tenant_admin',
        user_type => 'admin',
        email     => 'order_tenant_admin@test.com',
        name      => 'Order Tenant Admin',
    });

    my $tenant;
    eval {
        $tenant = Registry::DAO::Tenant->provision($db, {
            name  => 'Order Schema Tenant',
            slug  => 'order',
            users => [ $admin2 ],
        });
    };
    my $err = $@;

    ok !$err, "provision does not throw a DDL syntax error for slug 'order' (err: $err)"
        or diag "Error was: $err";
    ok $tenant, 'provision returned a Tenant object for slug "order"';
};
