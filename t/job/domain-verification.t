#!/usr/bin/env perl
# ABOUTME: Tests for the DomainVerification Minion job. Verifies that pending
# ABOUTME: domains are checked via Render API and status updates are persisted.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

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

# A primary user, because that is who hears about the domain. create_tenant
# does not add one, and without it the job has nobody to address -- which it
# now says out loud rather than reporting as a failure.
use Registry::DAO::User;
my $admin = Registry::DAO::User->create( $db, {
    username => 'job_test_admin', name => 'Job Admin',
    user_type => 'admin', email => 'job_admin@test.local' } );
$tenant->add_user( $db, $admin, 1 );
$db->query( 'SELECT copy_user(dest_schema => ?, user_id => ?)',
    'job_test_tenant', $admin->id );

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

subtest 'a domain out of time is told so, not silently dropped' => sub {
    # This used to assert the expired domain was simply "not checked", which is
    # the defect rather than the behaviour: the row stayed pending for ever, the
    # job stopped looking, and the tenant was never told anything. It is now
    # terminal AND announced (#21).
    $db->query(
        "INSERT INTO tenant_domains (tenant_id, domain, status, render_domain_id, created_at)
         VALUES (?, ?, 'pending', 'rdm_old', now() - interval '8 days')",
        $tenant->id, 'old-pending.example.com'
    );

    my $mock_render = MockRenderClient->new;
    my $job = Registry::Job::DomainVerification->new;
    $job->check_pending_domains($db, $mock_render);

    is(scalar @{ $mock_render->calls }, 0,
        'Render is not asked again about a domain that is out of time');

    my $row = $db->select('tenant_domains', '*',
        { domain => 'old-pending.example.com' })->hash;
    is $row->{status}, 'failed', 'it is terminal rather than pending for ever';
    like $row->{verification_error}, qr/within 7 days/,
        'and says why, in words an operator can act on';

    $db->delete('tenant_domains', { domain => 'old-pending.example.com' });
};

# Render's "not yet" -- a correct record that has not propagated. The defect
# this replaces: ANY non-confirmed result was marked `failed`, and the polling
# query only selects 'pending', so a domain was failed minutes after being
# added and never looked at again. Verification was single-shot.
{
    package PendingRenderClient;
    sub new { bless { calls => [] }, shift }
    sub verify_custom_domain {
        my ($self, $render_id) = @_;
        push @{ $self->{calls} }, $render_id;
        return { verificationStatus => 'pending',
                 verificationError  => 'DNS records not found yet' };
    }
    sub calls { shift->{calls} }
}

subtest 'a domain still propagating stays pending and keeps being polled' => sub {
    my $td = Registry::DAO::TenantDomain->create($db, {
        tenant_id        => $tenant->id,
        domain           => 'propagating.example.com',
        status           => 'pending',
        render_domain_id => 'rdm_prop',
    });

    my $render = PendingRenderClient->new;
    my $job    = Registry::Job::DomainVerification->new;

    $job->check_pending_domains($db, $render);
    my $row = $db->select('tenant_domains', '*', { id => $td->id })->hash;
    is $row->{status}, 'pending', 'still pending -- not failed for being slow';
    is $row->{verification_error}, 'DNS records not found yet',
        'and the reason is recorded, so the page can say what it waits for';

    # The half that mattered: it is asked again.
    $job->check_pending_domains($db, $render);
    is scalar @{ $render->calls }, 2, 'polled a second time';

    # And nobody has been emailed about a non-outcome.
    my $notes = $db->query(
        q{SELECT count(*) AS n FROM job_test_tenant.notifications
           WHERE metadata->>'domain' = ?}, 'propagating.example.com'
    )->hash->{n};
    is $notes, 0, 'and no message was sent about a domain that is merely slow';

    $db->delete('tenant_domains', { id => $td->id });
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

# -- the notifications, which are the point of unit C ------------------------
#
# Both templates have existed in full since custom domains shipped
# (Email::Template:427,460) and NOTHING created either, so a tenant learned the
# outcome of verification only by revisiting the page.

subtest 'a verified domain tells the tenant, once' => sub {
    my $td = Registry::DAO::TenantDomain->create($db, {
        tenant_id        => $tenant->id,
        domain           => 'good.example.com',
        status           => 'pending',
        render_domain_id => 'rdm_good',
    });

    my $job = Registry::Job::DomainVerification->new;
    $job->check_pending_domains($db, MockRenderClient->new);

    is $db->select('tenant_domains', '*', { id => $td->id })->hash->{status},
        'verified', 'verified';

    my $notes = $db->query(
        q{SELECT type::text AS type, subject, metadata
            FROM job_test_tenant.notifications
           WHERE metadata->>'domain' = ?}, 'good.example.com'
    )->expand->hashes->to_array;
    is scalar @$notes, 1, 'exactly one message queued';
    is $notes->[0]{type}, 'domain_verified', 'of the right type';
    like $notes->[0]{subject}, qr/good\.example\.com/, 'naming the domain';
    is $notes->[0]{metadata}{tenant_name}, 'Job Test Tenant',
        'and carrying the tenant name the template renders';

    # The job polls every fifteen minutes. A second pass must not re-tell.
    $job->check_pending_domains($db, MockRenderClient->new);
    is $db->query(
        q{SELECT count(*) AS n FROM job_test_tenant.notifications
           WHERE metadata->>'domain' = ?}, 'good.example.com' )->hash->{n},
        1, 'and a later run does not tell them again';

    $db->delete('tenant_domains', { id => $td->id });
};

subtest 'a real failure tells the tenant, with the reason and a way back' => sub {
    my $td = Registry::DAO::TenantDomain->create($db, {
        tenant_id        => $tenant->id,
        domain           => 'broken.example.com',
        status           => 'pending',
        render_domain_id => 'rdm_broken',
    });

    # A THROWN error is a genuine failure -- a bad credential, a domain Render
    # has never heard of -- as distinct from "not yet", which stays pending.
    my $job = Registry::Job::DomainVerification->new;
    $job->check_pending_domains($db, FailingRenderClient->new);

    is $db->select('tenant_domains', '*', { id => $td->id })->hash->{status},
        'failed', 'terminal';

    my $notes = $db->query(
        q{SELECT type::text AS type, metadata FROM job_test_tenant.notifications
           WHERE metadata->>'domain' = ?}, 'broken.example.com'
    )->expand->hashes->to_array;
    is scalar @$notes, 1, 'one message queued';
    is $notes->[0]{type}, 'domain_verification_failed', 'of the right type';
    ok $notes->[0]{metadata}{error}, 'carrying the error the page also shows';
    like $notes->[0]{metadata}{retry_url}, qr{/admin/domains},
        'and a way back -- the failed template offers a retry link';

    $db->delete('tenant_domains', { id => $td->id });
};

subtest 'and the drainer actually sends it' => sub {
    # The whole point of unit C. Queuing is not telling: before #484 nothing
    # drained the queue, so a notification row reached nobody. This asserts the
    # chain end to end rather than stopping at the row.
    my $td = Registry::DAO::TenantDomain->create($db, {
        tenant_id        => $tenant->id,
        domain           => 'delivered.example.com',
        status           => 'pending',
        render_domain_id => 'rdm_delivered',
    });

    Registry::Job::DomainVerification->new
        ->check_pending_domains($db, MockRenderClient->new);

    require Registry::Job::SendNotifications;
    {
        package QuietLog;
        sub new { bless {}, shift }
        sub info {} sub debug {} sub warn {} sub error {}
    }
    my $counts = Registry::Job::SendNotifications->send_for_tenant(
        $dao, 'job_test_tenant', QuietLog->new );

    ok $counts->{sent} >= 1, 'the drainer sent at least one message';
    my $sent = $db->query(
        q{SELECT sent_at FROM job_test_tenant.notifications
           WHERE metadata->>'domain' = ?}, 'delivered.example.com' )->hash;
    ok defined $sent->{sent_at},
        'and the domain message is stamped sent, so it is not re-sent';

    $db->delete('tenant_domains', { id => $td->id });
};

$tdb->cleanup_test_database;
done_testing();
