#!/usr/bin/env perl
# ABOUTME: Tests for the DomainVerification Minion job. Verifies that pending
# ABOUTME: domains are checked via Render API and status updates are persisted.
use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;

use Registry::Job::DomainVerification;
use Registry::DAO::TenantDomain;

my $tdb = Test::Registry::DB->new;
my $dao = $tdb->db;
my $db  = $dao->db;

$ENV{DB_URL} = $tdb->uri;

my $tenant = Test::Registry::Fixtures::create_tenant($dao, {
    name => 'Job Test Tenant',
    slug => 'job_test_tenant',
});

# Build a minimal mock Render client that records calls and returns canned responses
{
    package MockRenderClient;
    sub new { bless { calls => [] }, shift }
    sub verify_custom_domain {
        my ($self, $render_id) = @_;
        push @{ $self->{calls} }, $render_id;
        return { verificationStatus => 'confirmed' };   # simulate success
    }
    sub calls { shift->{calls} }
}

subtest 'Pending domains within 7 days are checked' => sub {
    my $td = Registry::DAO::TenantDomain->create($db, {
        tenant_id        => $tenant->id,
        domain           => 'pending-check.example.com',
        status           => 'pending',
        render_domain_id => 'rdm_abc123',
    });

    my $mock_render = MockRenderClient->new;
    my $job = Registry::Job::DomainVerification->new;
    $job->check_pending_domains($db, $mock_render);

    is(scalar @{ $mock_render->calls }, 1, 'Render verify called once');
    is($mock_render->calls->[0], 'rdm_abc123', 'Correct render_domain_id used');

    my $updated = Registry::DAO::TenantDomain->find($db, { id => $td->id });
    is($updated->status, 'verified', 'Domain status updated to verified');

    $db->delete('tenant_domains', { id => $td->id });
};

subtest 'Domains older than 7 days are skipped' => sub {
    # Insert domain with created_at > 7 days ago
    $db->query(
        "INSERT INTO tenant_domains (tenant_id, domain, status, render_domain_id, created_at)
         VALUES (?, ?, 'pending', 'rdm_old', now() - interval '8 days')",
        $tenant->id, 'old-pending.example.com'
    );

    my $mock_render = MockRenderClient->new;
    my $job = Registry::Job::DomainVerification->new;
    $job->check_pending_domains($db, $mock_render);

    is(scalar @{ $mock_render->calls }, 0, 'Expired domain not checked');

    $db->delete('tenant_domains', { domain => 'old-pending.example.com' });
};

subtest 'Failed verification stores error message' => sub {
    {
        package FailingRenderClient;
        sub new { bless {}, shift }
        sub verify_custom_domain { die "CNAME not found\n" }
    }

    my $td = Registry::DAO::TenantDomain->create($db, {
        tenant_id        => $tenant->id,
        domain           => 'fail-check.example.com',
        status           => 'pending',
        render_domain_id => 'rdm_fail',
    });

    my $failing_render = FailingRenderClient->new;
    my $job = Registry::Job::DomainVerification->new;
    $job->check_pending_domains($db, $failing_render);

    my $updated = Registry::DAO::TenantDomain->find($db, { id => $td->id });
    is($updated->status, 'failed', 'Domain status set to failed on error');
    like($updated->verification_error, qr/CNAME not found/, 'Error message stored');

    $db->delete('tenant_domains', { id => $td->id });
};

subtest 'Job registers with Minion' => sub {
    my $tasks_registered = {};
    my $mock_minion = bless {
        tasks => $tasks_registered,
    }, 'MockMinion';
    {
        package MockMinion;
        sub add_task { my ($self, $name, $cb) = @_; $self->{tasks}{$name} = $cb }
    }
    my $mock_app = bless { minion => $mock_minion }, 'MockApp';
    {
        package MockApp;
        sub minion { shift->{minion} }
    }

    Registry::Job::DomainVerification->register($mock_app);
    ok(exists $tasks_registered->{domain_verification},
        'domain_verification task registered with Minion');
};

$tdb->cleanup_test_database;
done_testing();
