#!/usr/bin/env perl
# ABOUTME: One resolver answers the platform terms a tenant's entitlement holds: version, plan, name, rate and price.
# ABOUTME: Every reader of those terms (fee stamp, fleet, revenue view, signup confirmation) agrees with it.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::PricingProbe qw(with_tenant_plan without_rate_check solo_linked_tenant give_tenant_terms);
use Test::Registry::Fixtures;
use Registry::PriceOps::PlatformTerms qw(platform_terms_for_tenant);
use Registry::PriceOps::RevenueShare qw(revenue_share_fraction_for_tenant);
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

my $SOLO_V1 = '00000000-0000-0000-0003-000000000001';

subtest 'resolver answers a tenants platform terms' => sub {
    with_tenant_plan( $db, $linked, { rate => '0.0137', amount_cents => 4200 },
        sub {
            my $held = $db->query( q{
                SELECT v.id, e.payment_plan_id, o.name FROM registry.entitlements e
                  JOIN registry.tenants t ON t.id = e.holder_tenant_id
                  JOIN registry.offer_versions v ON v.id = e.offer_version_id
                  JOIN registry.offers o ON o.id = v.offer_id
                 WHERE t.slug = ?
            }, $linked )->hash;

            my $terms = platform_terms_for_tenant( $db, $linked );
            is $terms->{id},      $held->{id},              'the held offer version id';
            is $terms->{plan_id}, $held->{payment_plan_id}, 'the accepted payment plan id';
            is $terms->{name},    $held->{name},            'its offer name';
            is $terms->{fraction}, '0.0137', 'its exact rate as a fraction';
            is $terms->{amount_cents}, 4200, 'its price';
            is $terms->{refund_policy}{kind}, 'keep_fee_with_admin_exception', "and Solo's refund policy";
        } );

    ok !eval { platform_terms_for_tenant( $db, 'terms_unlinked' ); 1 },
        'a tenant holding no platform entitlement is refused, not given the Free plan';
    like $@, qr/'terms_unlinked' holds no platform entitlement/, 'naming the tenant';
    ok !eval { revenue_share_fraction_for_tenant( $db, 'terms_unlinked' ); 1 },
        'as RevenueShare refuses it';

    ok !eval { platform_terms_for_tenant( $db, 'no_such_tenant' ); 1 },
        'a tenant row that is absent is refused the same way';
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
    return Registry::DAO::Payment->find( $db, { id => $p->id } )->platform_offer_version_id;
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
    with_tenant_plan( $db, $linked, { rate => '0.0137', amount_cents => 4200 },
        sub { readers_agree( $linked, 'a tenant on probe terms' ) } );

    readers_agree( $linked, 'a tenant holding Solo v1' );
};

subtest 'resolver refuses an over precise or out of range rate' => sub {
    for my $bad ( [ '0.00125', qr/4 decimal/ ], [ 2, qr/between 0 and 1/ ], [ -0.01, qr/between 0 and 1/ ] ) {
        my ( $rate, $why ) = @$bad;
        without_rate_check( $db, sub { with_tenant_plan( $db, $linked,
            { rate => $rate },
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
give_tenant_terms( $db, 'terms_second', { rate => '0.025', name => 'Solo' } );

subtest 'readers carry each tenants own terms' => sub {
    with_tenant_plan( $db, $linked, { rate => '0.0137', amount_cents => 4200 },
        sub { with_tenant_plan( $db, 'terms_second',
            { name => 'Second Probe', rate => '0.0311', amount_cents => 900 },
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
    with_tenant_plan( $db, 'terms_second', { rate => '0.0311', amount_cents => 900 },
        sub {
            my $tenant_db = $dao->connect_schema('terms_second')->db;
            is_deeply platform_terms_for_tenant( $tenant_db, 'terms_second' ),
                platform_terms_for_tenant( $db, 'terms_second' ),
                'the same terms on the tenant connection as on registry';
            is platform_terms_for_tenant( $tenant_db, 'terms_second' )->{fraction}, '0.0311',
                'not a refusal an empty clone would give';
        } );
};

$db->query( q{INSERT INTO registry.tenants (name, slug) VALUES ('Terms Stated', 'terms_stated')} );

subtest 'probe states terms the resolver returns' => sub {
    give_tenant_terms( $db, 'terms_stated',
        { rate => '0.0173', amount_cents => 1500, name => 'Stated Terms' } );

    my $terms = platform_terms_for_tenant( $db, 'terms_stated' );
    is $terms->{fraction}, '0.0173', 'it holds the stated rate';
    is $terms->{amount_cents}, 1500,           'and the stated monthly amount';
    is $terms->{name},         'Stated Terms', 'under the stated name';

    give_tenant_terms( $db, 'terms_stated', { rate => 0 } );
    is platform_terms_for_tenant( $db, 'terms_stated' )->{fraction}, 0,
        'stating terms again replaces them, for the rest of the test';
};

subtest 'probe publishes the terms it can through offer-publishing' => sub {
    my $published_by_run = sub ($id) {
        $db->query( q{SELECT 1 FROM registry.workflow_runs r JOIN registry.workflows w ON w.id = r.workflow_id
                       WHERE w.slug = 'offer-publishing' AND r.data->>'published_offer_version_id' = ?}, $id )->rows;
    };
    my $retired = sub ($id) {
        $db->query( 'SELECT superseded_at IS NOT NULL FROM registry.offer_versions WHERE id = ?', $id )->array->[0];
    };

    give_tenant_terms( $db, 'terms_stated', { rate => '0.0173', amount_cents => 1500, name => 'Published Terms' } );
    my $given = platform_terms_for_tenant( $db, 'terms_stated' );
    ok $published_by_run->( $given->{id} ), 'give_tenant_terms publishes its version through the workflow';
    ok $retired->( $given->{id} ), 'and retires it, so signup never offers it';

    with_tenant_plan( $db, 'terms_stated', { rate => '0.0311' }, sub {
        my $probe = platform_terms_for_tenant( $db, 'terms_stated' );
        ok $published_by_run->( $probe->{id} ), 'with_tenant_plan publishes its version through the workflow';
        ok $retired->( $probe->{id} ), 'and retires it too';
    } );
};

subtest 'probe refuses an over precise or out of range rate' => sub {
    my $plans  = sub { $db->query('SELECT count(*) FROM registry.offer_versions')->array->[0] };
    my $before = platform_terms_for_tenant( $db, 'terms_stated' );
    my $count  = $plans->();
    for my $bad ( [ '0.00125', qr/4 decimal/ ], [ 2, qr/between 0 and 1/ ], [ -0.01, qr/between 0 and 1/ ] ) {
        my ( $rate, $why ) = @$bad;
        ok !eval { give_tenant_terms( $db, 'terms_stated', { rate => $rate } ); 1 },
            "a rate of $rate is refused";
        like $@, qr/give_tenant_terms/, "by the probe itself, not the database";
        like $@, $why,                  "naming what is wrong with $rate";
    }
    is $plans->(), $count, 'no offer version was written';
    is_deeply platform_terms_for_tenant( $db, 'terms_stated' ), $before,
        'and the tenant keeps the terms it held';
};

subtest 'probe leaves other tenants terms unchanged' => sub {
    my %before = map { $_ => platform_terms_for_tenant( $db, $_ ) } $linked, 'terms_second';
    give_tenant_terms( $db, 'terms_stated', { rate => '0.0421', name => 'Only Mine' } );
    is_deeply platform_terms_for_tenant( $db, $_ ), $before{$_}, "$_ holds the terms it held"
        for sort keys %before;
};

subtest 'scoped probe restores terms after a die' => sub {
    my $before = platform_terms_for_tenant( $db, $linked );
    ok !eval {
        with_tenant_plan( $db, $linked, { rate => '0.0999' },
            sub { die "block failed\n" } );
        1;
    }, 'the block dies';
    is $@, "block failed\n", 'and its error propagates';
    is_deeply platform_terms_for_tenant( $db, $linked ), $before, 'the prior terms are back';
};

subtest 'probe never edits an existing plan' => sub {
    my $all  = sub { $db->query(q{SELECT v.*, p.id AS plan_id, p.kind, p.fraction FROM registry.offer_versions v
                                   LEFT JOIN registry.offer_version_payment_plans p ON p.offer_version_id = v.id
                                   ORDER BY v.id, p.id})->hashes->to_array };
    my ( $versions, $solo_before ) = ( $all->(), platform_version_terms_of($SOLO_V1) );
    ok $solo_before, 'the seeded Solo v1 is there';

    give_tenant_terms( $db, 'terms_stated', { rate => '0.0999', amount_cents => 7 } );

    is_deeply platform_version_terms_of($SOLO_V1), $solo_before, "Solo v1's terms are unchanged";
    my %was = map { ( $_->{id} . ( $_->{plan_id} // '' ) ) => 1 } @$versions;
    is_deeply [ grep { $was{ $_->{id} . ( $_->{plan_id} // '' ) } } @{ $all->() } ], $versions,
        'as is every offer version and plan that existed before';
};

sub platform_version_terms_of ($id) {
    return Registry::PriceOps::PlatformTerms::platform_version_terms( $db, $id, 'revenue_share' );
}

subtest 'publishable probe inside without rate check refuses instead of hanging' => sub {
    # The probe publishes over a second connection, which would wait forever on
    # the ALTER TABLE lock without_rate_check holds on this one.
    my $err;
    without_rate_check( $db, sub {
        # A lock timeout on the probe's own connection turns a hang into an error.
        local $ENV{PGOPTIONS} = '-c lock_timeout=5s';
        eval { give_tenant_terms( $db, 'terms_second', { rate => '0.02' } ) };
        $err = $@;
    } );
    unlike $err, qr/lock timeout/i, 'it does not wait on the lock';
    like $err, qr/without_rate_check/, 'it dies naming the wrapper';
};

done_testing;
