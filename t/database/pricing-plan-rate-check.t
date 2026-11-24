#!/usr/bin/env perl
# ABOUTME: A plan rate written straight into SQL meets the rule PricingPlan->create enforces.
# ABOUTME: A fraction from 0 to 1 with at most 4 decimals, in every schema; the deploy refuses rows that break it.
use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use Test::Registry::Fixtures;
use App::Sqitch;
use Capture::Tiny qw( capture );
use Test::PostgreSQL;
use Mojo::Pg;

my $pgsql = Test::PostgreSQL->new() or plan skip_all => $Test::PostgreSQL::errstr;
my $uri   = $pgsql->uri;
# Held, and on registry's search_path, as Registry::DAO sets it, for create_tenant.
my $pg    = Mojo::Pg->new($uri)->search_path( [ 'registry', 'public' ] );
my $db    = $pg->db;

sub deploy (@to) {
    # Sqitch's exception says only that psql failed; the migration's message is on stderr.
    my ( undef, $err, $ok ) = capture {
        eval { App::Sqitch->new->run( 'sqitch', 'deploy', '-t', $uri, @to ? ( '--to', @to ) : () ); 1 };
    };
    die $err unless $ok;
}

sub plan_with_rate ( $pct, $schema = 'registry' ) {
    $db->query( qq{INSERT INTO $schema.pricing_plans
                    (plan_name, plan_type, pricing_model_type, pricing_configuration)
                  VALUES ('Rate check', 'standard', 'percentage', ?::jsonb)},
        qq({"percentage": $pct}) );
}

sub tenant ($slug) {
    Test::Registry::Fixtures::create_tenant( $db, { name => $slug, slug => $slug } );
}

lives_ok { deploy('pricing-plan-rate-check^') } 'deploy to the parent change succeeds';

subtest 'the deploy refuses, naming the tenant schema, a bad rate held by a tenant' => sub {
    tenant('rate_tenant');
    plan_with_rate( '1.5', 'rate_tenant' );

    throws_ok { deploy() } qr/schema rate_tenant has a pricing plan/, 'the deploy fails naming the tenant';

    $db->query( q{DELETE FROM rate_tenant.pricing_plans} );
};

subtest 'the deploy refuses a plan whose rate is already out of range' => sub {
    plan_with_rate('0.12345');

    throws_ok { deploy() } qr/schema registry has a pricing plan/, 'the deploy fails naming the schema';
    ok !$db->query( q{SELECT 1 FROM pg_constraint WHERE conname = 'pricing_plans_percentage_rate_check'} )->rows,
        'and adds no constraint';
    is $db->query( q{SELECT count(*) AS n FROM registry.pricing_plans
                      WHERE pricing_configuration->>'percentage' = '0.12345'} )->hash->{n},
        1, 'leaving the bad row for a person to fix';

    $db->query( q{DELETE FROM registry.pricing_plans WHERE pricing_configuration->>'percentage' = '0.12345'} );
    lives_ok { deploy() } 'once it is gone the deploy succeeds';
};

subtest 'a plan rate outside 0..1 or with more than 4 decimals is rejected' => sub {
    for my $bad ( '1.5', '-0.01', '0.12345', '"2%"' ) {
        throws_ok { plan_with_rate($bad) } qr/pricing_plans_percentage_rate_check/,
            "a rate of $bad is refused";
    }
    for my $good ( '0', '1', '0.025', '0.0001', '0.02500' ) {
        lives_ok { plan_with_rate($good) } "a rate of $good is stored";
    }
    lives_ok {
        $db->query( q{INSERT INTO registry.pricing_plans (plan_name, plan_type, pricing_model_type)
                      VALUES ('No rate', 'standard', 'fixed')} );
    } 'a fixed plan with no rate is not constrained';
};

subtest 'a percentage or hybrid plan with no rate is rejected' => sub {
    for my $type (qw( percentage hybrid )) {
        for my $config ( '{}', '{"percentage": null}' ) {
            throws_ok {
                $db->query( q{INSERT INTO registry.pricing_plans
                                (plan_name, plan_type, pricing_model_type, pricing_configuration)
                              VALUES ('No rate', 'standard', ?, ?::jsonb)}, $type, $config );
            } qr/pricing_plans_percentage_rate_check/, "a $type plan with $config is refused";
        }
    }
};

subtest 'a tenant schema refuses a rate of 1.5' => sub {
    tenant('new_rate_tenant');
    for my $slug (qw( rate_tenant new_rate_tenant )) {
        throws_ok { plan_with_rate( '1.5', $slug ) } qr/pricing_plans_percentage_rate_check/,
            "$slug.pricing_plans refuses it";
    }
};

done_testing;
