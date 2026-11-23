#!/usr/bin/env perl
# ABOUTME: A membership carries its own role, so authority can be read per tenant (ruling 4).
# ABOUTME: Plants members of every user_type, deploys, asserts the backfill copied each, and reverts.

use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use App::Sqitch;
use Capture::Tiny qw( capture_stderr );
use Test::PostgreSQL;
use Mojo::Pg;

use constant CHANGE => 'tenant-users-role';

my $pgsql = Test::PostgreSQL->new() or plan skip_all => $Test::PostgreSQL::errstr;
my $uri    = $pgsql->uri;
my $sqitch = App::Sqitch->new();

# Deploy to this change's parent so memberships can be planted before it runs.
# See retire-registry-plus-plan.t for why the change is named with '^'.
lives_ok { $sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', CHANGE . '^' ) }
    'deploy to the parent change succeeds';

my $db = Mojo::Pg->new($uri)->db;

my $tenant_id = $db->query(
    q{INSERT INTO registry.tenants (name, slug) VALUES ('Role Fixture', 'role_fixture')
      RETURNING id}
)->hash->{id};

# One member of every type check_user_type allows: the backfill has to carry
# each across, not just the admin one the platform guard reads.
my %member;
for my $type (qw( parent student staff admin )) {
    $member{$type} = $db->query(
        q{INSERT INTO registry.users (username, user_type) VALUES (?, ?) RETURNING id},
        "role_$type", $type
    )->hash->{id};
    $db->query( q{INSERT INTO registry.tenant_users (tenant_id, user_id) VALUES (?, ?)},
        $tenant_id, $member{$type} );
}

sub has_role_column () {
    return $db->query(
        q{SELECT 1 FROM information_schema.columns
           WHERE table_schema = 'registry' AND table_name = 'tenant_users'
             AND column_name = 'role'}
    )->rows;
}

ok !has_role_column(), 'before the change, a membership has no role';

lives_ok { $sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', CHANGE ) }
    'the change deploys';

for my $type (qw( parent student staff admin )) {
    is $db->query(
        q{SELECT role FROM registry.tenant_users WHERE tenant_id = ? AND user_id = ?},
        $tenant_id, $member{$type}
    )->hash->{role}, $type, "the membership of a user whose user_type is $type has role $type";
}

# Including the memberships the seed created, the platform owner's among them.
is $db->query(
    q{SELECT count(*) FROM registry.tenant_users tu
        JOIN registry.users u ON u.id = tu.user_id
       WHERE tu.role IS DISTINCT FROM u.user_type}
)->array->[0], 0, 'every existing membership keeps its user_type as its role';

my $newcomer = $db->query(
    q{INSERT INTO registry.users (username, user_type) VALUES ('role_newcomer', 'admin') RETURNING id}
)->hash->{id};
$db->query( q{INSERT INTO registry.tenant_users (tenant_id, user_id) VALUES (?, ?)},
    $tenant_id, $newcomer );
is $db->query(
    q{SELECT role FROM registry.tenant_users WHERE tenant_id = ? AND user_id = ?},
    $tenant_id, $newcomer
)->hash->{role}, 'parent',
    'a membership written without a role gets the default, which grants nothing';

my $stranger = $db->query(
    q{INSERT INTO registry.users (username, user_type) VALUES ('role_stranger', 'parent') RETURNING id}
)->hash->{id};
{
    local $db->dbh->{PrintError} = 0;
    throws_ok {
        $db->query(
            q{INSERT INTO registry.tenant_users (tenant_id, user_id, role) VALUES (?, ?, 'operator')},
            $tenant_id, $stranger );
    } qr/check_tenant_user_role/, 'a role check_user_type would not allow is refused';
    throws_ok {
        $db->query(
            q{INSERT INTO registry.tenant_users (tenant_id, user_id, role) VALUES (?, ?, NULL)},
            $tenant_id, $stranger );
    } qr/not-null|null value/i, 'and so is no role at all';
}

# psql reports the revert's progress on stderr; keep it out of the TAP stream.
capture_stderr {
    lives_ok { $sqitch->run( 'sqitch', 'revert', '-t', $uri, '--to', CHANGE . '^', '-y' ) }
        'the revert runs';
};
ok !has_role_column(), 'reverting drops the role column';
is $db->query(
    q{SELECT count(*) FROM registry.tenant_users WHERE tenant_id = ?}, $tenant_id
)->array->[0], 5, 'and keeps every membership';

done_testing;
