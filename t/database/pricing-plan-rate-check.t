#!/usr/bin/env perl
# ABOUTME: A plan rate written straight into SQL meets the rule PricingPlan->create enforces.
# ABOUTME: A fraction from 0 to 1 with at most 4 decimals; the deploy refuses rows that break it.
use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use App::Sqitch;
use Capture::Tiny qw( capture );
use Test::PostgreSQL;
use Mojo::Pg;

my $pgsql = Test::PostgreSQL->new() or plan skip_all => $Test::PostgreSQL::errstr;
my $uri   = $pgsql->uri;
my $db    = Mojo::Pg->new($uri)->db;

sub deploy (@to) {
    my ( undef, $err ) = capture {
        App::Sqitch->new->run( 'sqitch', 'deploy', '-t', $uri, @to ? ( '--to', @to ) : () );
    };
}

sub plan_with_rate ($pct) {
    $db->query( q{INSERT INTO registry.pricing_plans
                    (plan_name, plan_type, pricing_model_type, pricing_configuration)
                  VALUES ('Rate check', 'standard', 'percentage', ?::jsonb)},
        qq({"percentage": $pct}) );
}

lives_ok { deploy('pricing-plan-rate-check^') } 'deploy to the parent change succeeds';

subtest 'the deploy refuses a plan whose rate is already out of range' => sub {
    plan_with_rate('0.12345');

    throws_ok { deploy() } qr/./, 'the deploy fails';
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
    } 'a plan with no rate is not constrained';
};

done_testing;
