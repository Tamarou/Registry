#!/usr/bin/env perl
# ABOUTME: Unit tests for Registry::DAO::TenantDomain. Covers CRUD, domain
# ABOUTME: validation, primary transitions, and canonical_domain side-effects.
use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;

use Registry::DAO::TenantDomain;
use Registry::DAO::Tenant;

my $tdb = Test::Registry::DB->new;
my $dao = $tdb->db;
my $db  = $dao->db;

my $tenant = Test::Registry::Fixtures::create_tenant($dao, {
    name => 'Domain Test Tenant',
    slug => 'domain_test_tenant',
});

subtest 'CRUD operations' => sub {
    my $td = Registry::DAO::TenantDomain->create($db, {
        tenant_id => $tenant->id,
        domain    => 'example.com',
        status    => 'pending',
    });
    ok($td, 'domain row created');
    is($td->domain, 'example.com', 'domain field correct');
    is($td->status, 'pending',     'status defaults to pending');
    is($td->is_primary, 0,         'is_primary defaults to false');

    my $found = Registry::DAO::TenantDomain->find($db, { id => $td->id });
    ok($found, 'find by id');
    is($found->domain, 'example.com', 'find returns correct row');

    $db->delete('tenant_domains', { id => $td->id });
};

subtest 'find_by_domain' => sub {
    my $td = Registry::DAO::TenantDomain->create($db, {
        tenant_id => $tenant->id,
        domain    => 'findme.example.com',
        status    => 'verified',
    });

    my $found = Registry::DAO::TenantDomain->find_by_domain($db, 'findme.example.com');
    ok($found, 'found by domain name');
    is($found->tenant_id, $tenant->id, 'belongs to correct tenant');

    my $missing = Registry::DAO::TenantDomain->find_by_domain($db, 'nothere.example.com');
    ok(!$missing, 'returns undef for unknown domain');

    $db->delete('tenant_domains', { id => $td->id });
};

subtest 'for_tenant returns all rows (no limit enforcement)' => sub {
    my $td1 = Registry::DAO::TenantDomain->create($db, {
        tenant_id => $tenant->id,
        domain    => 'first.example.com',
    });
    my $td2 = Registry::DAO::TenantDomain->create($db, {
        tenant_id => $tenant->id,
        domain    => 'second.example.com',
    });

    my @domains = Registry::DAO::TenantDomain->for_tenant($db, $tenant->id);
    is(scalar @domains, 2, 'for_tenant returns all rows');

    $db->delete('tenant_domains', { tenant_id => $tenant->id });
};

subtest 'set_primary updates tenant canonical_domain' => sub {
    my $td = Registry::DAO::TenantDomain->create($db, {
        tenant_id => $tenant->id,
        domain    => 'primary.example.com',
        status    => 'verified',
    });

    $td->set_primary($db);
    is($td->is_primary, 1, 'is_primary set to true on the domain row');

    my $reloaded_tenant = Registry::DAO::Tenant->find($db, { id => $tenant->id });
    is($reloaded_tenant->canonical_domain, 'primary.example.com',
        'set_primary also updates tenants.canonical_domain');

    # A second set_primary clears the first
    my $td2 = Registry::DAO::TenantDomain->create($db, {
        tenant_id => $tenant->id,
        domain    => 'other.example.com',
        status    => 'verified',
    });
    $td2->set_primary($db);

    my $reloaded_first = Registry::DAO::TenantDomain->find($db, { id => $td->id });
    is($reloaded_first->is_primary, 0, 'previous primary cleared');

    my $reloaded_tenant2 = Registry::DAO::Tenant->find($db, { id => $tenant->id });
    is($reloaded_tenant2->canonical_domain, 'other.example.com',
        'canonical_domain updated to new primary');

    $db->delete('tenant_domains', { tenant_id => $tenant->id });
    $db->update('tenants', { canonical_domain => undef }, { id => $tenant->id });
};

subtest 'mark_verified updates canonical_domain when is_primary' => sub {
    my $td = Registry::DAO::TenantDomain->create($db, {
        tenant_id  => $tenant->id,
        domain     => 'verify-primary.example.com',
        status     => 'pending',
        is_primary => 1,
    });

    $td->mark_verified($db);
    is($td->status, 'verified', 'status updated to verified');
    ok($td->verified_at, 'verified_at timestamp set');

    my $reloaded_tenant = Registry::DAO::Tenant->find($db, { id => $tenant->id });
    is($reloaded_tenant->canonical_domain, 'verify-primary.example.com',
        'mark_verified updates canonical_domain when domain is_primary');

    $db->delete('tenant_domains', { id => $td->id });
    $db->update('tenants', { canonical_domain => undef }, { id => $tenant->id });
};

subtest 'mark_verified does not change canonical_domain when not primary' => sub {
    my $td = Registry::DAO::TenantDomain->create($db, {
        tenant_id  => $tenant->id,
        domain     => 'verify-nonprimary.example.com',
        status     => 'pending',
        is_primary => 0,
    });

    $td->mark_verified($db);
    is($td->status, 'verified', 'status updated to verified');

    my $reloaded_tenant = Registry::DAO::Tenant->find($db, { id => $tenant->id });
    is($reloaded_tenant->canonical_domain, undef,
        'canonical_domain unchanged when non-primary domain is verified');

    $db->delete('tenant_domains', { id => $td->id });
};

subtest 'remove clears canonical_domain when removing primary' => sub {
    my $td = Registry::DAO::TenantDomain->create($db, {
        tenant_id  => $tenant->id,
        domain     => 'to-remove.example.com',
        status     => 'verified',
        is_primary => 1,
    });
    $db->update('tenants', { canonical_domain => 'to-remove.example.com' },
        { id => $tenant->id });

    $td->remove($db);

    my $gone = Registry::DAO::TenantDomain->find($db, { id => $td->id });
    ok(!$gone, 'row deleted');

    my $reloaded_tenant = Registry::DAO::Tenant->find($db, { id => $tenant->id });
    is($reloaded_tenant->canonical_domain, undef,
        'remove clears canonical_domain when primary domain is removed');
};

subtest 'remove does not clear canonical_domain for non-primary' => sub {
    $db->update('tenants', { canonical_domain => 'keeper.example.com' }, { id => $tenant->id });

    my $td = Registry::DAO::TenantDomain->create($db, {
        tenant_id  => $tenant->id,
        domain     => 'non-primary-remove.example.com',
        status     => 'verified',
        is_primary => 0,
    });

    $td->remove($db);

    my $reloaded_tenant = Registry::DAO::Tenant->find($db, { id => $tenant->id });
    is($reloaded_tenant->canonical_domain, 'keeper.example.com',
        'removing a non-primary domain leaves canonical_domain unchanged');

    $db->update('tenants', { canonical_domain => undef }, { id => $tenant->id });
};

subtest 'mark_failed records error' => sub {
    my $td = Registry::DAO::TenantDomain->create($db, {
        tenant_id => $tenant->id,
        domain    => 'fail.example.com',
        status    => 'pending',
    });

    $td->mark_failed($db, 'CNAME record not found');
    is($td->status, 'failed', 'status set to failed');
    is($td->verification_error, 'CNAME record not found', 'error stored');

    $db->delete('tenant_domains', { id => $td->id });
};

subtest 'domain format validation' => sub {
    my @valid = qw(example.com www.example.com sub.domain.example.com);
    my @invalid = (
        '192.168.1.1',
        'localhost',
        'dance.tinyartempire.com',
        '',
        'not_a_domain',
    );

    for my $d (@valid) {
        my $err = Registry::DAO::TenantDomain->validate_domain($d);
        ok(!$err, "valid domain accepted: $d");
    }
    for my $d (@invalid) {
        my $err = Registry::DAO::TenantDomain->validate_domain($d);
        ok($err, "invalid domain rejected: $d");
    }
};

subtest 'uniqueness constraint' => sub {
    my $other_tenant = Test::Registry::Fixtures::create_tenant($dao, {
        name => 'Other Tenant',
        slug => 'other_unique_tenant',
    });

    Registry::DAO::TenantDomain->create($db, {
        tenant_id => $tenant->id,
        domain    => 'unique.example.com',
    });

    eval {
        Registry::DAO::TenantDomain->create($db, {
            tenant_id => $other_tenant->id,
            domain    => 'unique.example.com',
        });
    };
    ok($@, 'duplicate domain rejected by uniqueness constraint');

    $db->delete('tenant_domains', { tenant_id => $tenant->id });
};

subtest 'cascade delete with tenant' => sub {
    my $temp_tenant = Test::Registry::Fixtures::create_tenant($dao, {
        name => 'Temp Tenant',
        slug => 'temp_cascade_tenant',
    });
    Registry::DAO::TenantDomain->create($db, {
        tenant_id => $temp_tenant->id,
        domain    => 'cascade.example.com',
    });

    $db->delete('tenants', { id => $temp_tenant->id });

    my $gone = Registry::DAO::TenantDomain->find_by_domain($db, 'cascade.example.com');
    ok(!$gone, 'domain row deleted when tenant is deleted');
};

done_testing();
