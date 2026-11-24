#!/usr/bin/env perl
# ABOUTME: One resolver answers the platform terms a tenant holds: id, name, rate and monthly amount.
# ABOUTME: Every reader of those terms (fee stamp, fleet, revenue view, signup confirmation) agrees with it.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::PricingProbe qw(with_tenant_plan without_rate_check solo_linked_tenant give_tenant_terms);
use Test::Registry::Fixtures;
use Registry::PriceOps::PlatformTerms qw(platform_terms_for_tenant);
use Registry::PriceOps::RevenueShare qw(revenue_share_plan_for_tenant);
use Registry::DAO::Payment;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::WorkflowRun;
use Registry::DAO::WorkflowSteps::RegisterTenant;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $linked = solo_linked_tenant($db);

$db->query( q{INSERT INTO registry.tenants (name, slug) VALUES ('Terms Unlinked', 'terms_unlinked')} );

my $free = $db->query( q{
    SELECT id, plan_name, amount_cents FROM registry.pricing_plans
     WHERE plan_scope = 'platform' AND metadata->>'default' = 'true'
       AND superseded_at IS NULL
} )->hash;

subtest 'resolver answers a tenants platform terms' => sub {
    with_tenant_plan( $db, $linked,
        { pricing_configuration => { percentage => '0.0137' }, amount_cents => 4200 },
        sub {
            my $plan = $db->query( q{
                SELECT p.id, p.plan_name FROM registry.tenants t
                  JOIN registry.pricing_plans p ON p.id = t.platform_pricing_plan_id
                 WHERE t.slug = ?
            }, $linked )->hash;

            my $terms = platform_terms_for_tenant( $db, $linked );
            is $terms->{id},   $plan->{id},        'the linked plan id';
            is $terms->{name}, $plan->{plan_name}, 'its name';
            cmp_ok abs( $terms->{fraction} - 0.0137 ), '<', 1e-9, 'its rate as a fraction';
            is $terms->{amount_cents}, 4200, 'its monthly amount';
            ok !grep( /refund/, keys %$terms ), 'and no refund flag: refunds keep the fee (ADR 003)';
        } );

    my $terms = platform_terms_for_tenant( $db, 'terms_unlinked' );
    my ( $fraction, $plan_id ) = revenue_share_plan_for_tenant( $db, 'terms_unlinked' );
    is $terms->{id}, $free->{id}, 'an unlinked tenant holds the Free plan';
    is $terms->{id}, $plan_id,    'as RevenueShare resolves it';
    cmp_ok abs( $terms->{fraction} - $fraction ), '<', 1e-9, 'at the same rate';
    is $terms->{name},         $free->{plan_name},    'named as the Free plan';
    is $terms->{amount_cents}, $free->{amount_cents}, 'with its monthly amount';

    my $absent = platform_terms_for_tenant( $db, 'no_such_tenant' );
    is $absent->{id}, $free->{id}, 'a tenant row that is absent falls back the same way';
};

my $payer = Registry::DAO::User->create( $db, {
    username => 'terms_payer', name => 'Terms Payer', user_type => 'parent',
    email => 'terms_payer@test.local' } );

# The fee stamp on a row with no seller account, which reads the tenant's live
# terms (a connected row stamps what create snapshotted from RevenueShare).
sub stamped_terms_id ($slug) {
    my $p = Registry::DAO::Payment->create( $db, {
        user_id => $payer->id, amount_cents => 10000, status => 'pending',
        metadata => { tenant_slug => $slug, enrollment_items => [] },
    } );
    $p->record_platform_fee( $db, { application_fee_amount => 0 } );
    return Registry::DAO::Payment->find( $db, { id => $p->id } )->platform_pricing_plan_id;
}

sub signup_plan ($slug) {
    my $tenant_id = $db->select( 'registry.tenants', 'id', { slug => $slug } )->hash->{id};
    my $step = Registry::DAO::WorkflowSteps::RegisterTenant->new(
        id => 0, slug => 'complete', workflow_id => 0, description => '',
        class => 'Registry::DAO::WorkflowSteps::RegisterTenant' );
    my $run = Registry::DAO::WorkflowRun->new( workflow_id => 0, created_at => 'now', data => { tenant => $tenant_id } );
    return $step->prepare_completion_data( $db, $run )->{plan};
}

sub readers_for ($slug) {
    my ($fleet)   = grep { $_->{slug} eq $slug } @{ Registry::DAO::Tenant->fleet($db) };
    my ($revenue) = grep { $_->{slug} eq $slug }
        @{ Registry::DAO::Tenant->platform_revenue($db)->{tenants} };
    return {
        stamp   => stamped_terms_id($slug),
        fleet   => $fleet,
        revenue => $revenue,
        signup  => signup_plan($slug),
    };
}

sub readers_agree ( $slug, $label ) {
    my $terms = platform_terms_for_tenant( $db, $slug );
    my $r     = readers_for($slug);
    is $r->{stamp}, $terms->{id}, "$label: the fee stamp names the terms";
    is $r->{fleet}{plan_name},   $terms->{name}, "$label: the fleet row names them";
    is $r->{revenue}{plan_name}, $terms->{name}, "$label: the revenue row names them";
    cmp_ok abs( $r->{revenue}{rate_pct} - $terms->{fraction} * 100 ), '<', 1e-9,
        "$label: at their rate";
    is_deeply $r->{signup}, {
        plan_name             => $terms->{name},
        monthly_amount        => $terms->{amount_cents},
        revenue_share_percent => $terms->{fraction} * 100,
    }, "$label: the signup confirmation states them";
}

subtest 'readers agree with the resolver' => sub {
    with_tenant_plan( $db, $linked,
        { pricing_configuration => { percentage => '0.0137' }, amount_cents => 4200 },
        sub { readers_agree( $linked, 'a tenant on a probe plan' ) } );

    readers_agree( 'terms_unlinked', 'a tenant with no linked plan' );
};

subtest 'resolver refuses an over precise or out of range rate' => sub {
    for my $bad ( [ '0.00125', qr/4 decimal/ ], [ 2, qr/between 0 and 1/ ], [ -0.01, qr/between 0 and 1/ ] ) {
        my ( $rate, $why ) = @$bad;
        without_rate_check( $db, sub { with_tenant_plan( $db, $linked,
            { pricing_configuration => { percentage => $rate } },
            sub {
                my $terms = eval { platform_terms_for_tenant( $db, $linked ) };
                ok !defined $terms, "a rate of $rate is refused";
                like $@, $why, "naming what is wrong with $rate";
            } ) } );
    }
};

# A second linked tenant with a schema of its own, so a tenant-schema
# connection has an empty registry clone to (wrongly) read.
Test::Registry::Fixtures::create_tenant( $db, { name => 'Terms Second', slug => 'terms_second' } );
$db->query( q{UPDATE registry.tenants SET platform_pricing_plan_id =
                (SELECT platform_pricing_plan_id FROM registry.tenants WHERE slug = ?)
               WHERE slug = 'terms_second'}, $linked );

subtest 'readers carry each tenants own terms' => sub {
    with_tenant_plan( $db, $linked,
        { pricing_configuration => { percentage => '0.0137' }, amount_cents => 4200 },
        sub { with_tenant_plan( $db, 'terms_second',
            { plan_name => 'Second Probe', pricing_configuration => { percentage => '0.0311' }, amount_cents => 900 },
            sub {
                my $one = platform_terms_for_tenant( $db, $linked );
                my $two = platform_terms_for_tenant( $db, 'terms_second' );
                isnt $one->{id}, $two->{id}, 'the two tenants hold different terms';
                isnt $one->{name}, $two->{name}, 'with different names';

                readers_agree( $linked,        'the first tenant' );
                readers_agree( 'terms_second', 'the second tenant' );
            } ) } );
};

subtest 'resolver reads registry from a tenant connection' => sub {
    with_tenant_plan( $db, 'terms_second',
        { pricing_configuration => { percentage => '0.0311' }, amount_cents => 900 },
        sub {
            my $tenant_db = $dao->connect_schema('terms_second')->db;
            is_deeply platform_terms_for_tenant( $tenant_db, 'terms_second' ),
                platform_terms_for_tenant( $db, 'terms_second' ),
                'the same terms on the tenant connection as on registry';
            isnt platform_terms_for_tenant( $tenant_db, 'terms_second' )->{id}, $free->{id},
                'not the Free fallback an empty clone would give';
        } );
};

$db->query( q{INSERT INTO registry.tenants (name, slug) VALUES ('Terms Stated', 'terms_stated')} );

subtest 'probe states terms the resolver returns' => sub {
    give_tenant_terms( $db, 'terms_stated',
        { rate => '0.0173', amount_cents => 1500, name => 'Stated Terms' } );

    my $terms = platform_terms_for_tenant( $db, 'terms_stated' );
    isnt $terms->{id}, $free->{id}, 'the tenant no longer falls back to Free';
    cmp_ok abs( $terms->{fraction} - 0.0173 ), '<', 1e-9, 'it holds the stated rate';
    is $terms->{amount_cents}, 1500,           'and the stated monthly amount';
    is $terms->{name},         'Stated Terms', 'under the stated name';

    give_tenant_terms( $db, 'terms_stated', { rate => 0 } );
    is platform_terms_for_tenant( $db, 'terms_stated' )->{fraction}, 0,
        'stating terms again replaces them, for the rest of the test';
};

done_testing;
