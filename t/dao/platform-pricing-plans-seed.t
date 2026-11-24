#!/usr/bin/env perl
# ABOUTME: Integration test that a fresh deploy publishes exactly one platform offer signup can list.
# ABOUTME: Guards #268 — fresh deploys must offer a buyable plan; the Free fallback is never offered.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::PriceOps::PlatformTerms qw( platform_offers_to_tenants );

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;     # Registry::DAO
my $db      = $dao->db;         # Mojo::Pg::Database

my $offers = platform_offers_to_tenants($db);

subtest 'signup offers selectable plans' => sub {
    # By what the offer IS, not by what it is called. What must hold on a fresh
    # deploy is that exactly one offer can be bought -- none and signup is a
    # dead end.
    is scalar(@$offers), 1, 'exactly one published platform offer to tenants on a fresh deploy'
        or diag 'offered: ' . join( ', ', map { $_->{name} } @$offers );
    is $offers->[0]{name}, 'Solo', 'and it is Solo';
};

subtest 'Free platform fallback plan exists and is not selectable' => sub {
    my $row = $db->query(q{
        SELECT plan_name, amount_cents, pricing_model_type,
               pricing_configuration->>'percentage' AS pct
          FROM registry.pricing_plans
         WHERE plan_scope = 'platform'
           AND metadata->>'default' = 'true'
    })->hash;
    ok $row, 'a platform-scope default plan exists';
    is $row->{pricing_model_type}, 'percentage', 'Free plan is percentage-typed';
    cmp_ok $row->{pct} + 0, '==', 0, 'Free plan rate is 0';
    is $row->{amount_cents}, 0, 'Free plan carries no dollar amount';

    ok !( grep { $_->{name} eq $row->{plan_name} } @$offers ), 'Free is not an offer signup lists';
};

subtest 'every selectable plan has a usable revenue-share rate' => sub {
    # A tenant that picks a plan with no resolvable rate cannot take payments at
    # all: the fee resolver dies rather than guess, so every enrollment charge
    # fails. platform_offers_to_tenants reads each rate through rate_fraction,
    # which dies on one that is absent or not a fraction; this pins the range.
    for my $offer (@$offers) {
        ok defined $offer->{fraction}, "$offer->{name}: has a revenue-share rate";
        cmp_ok $offer->{fraction}, '>', 0, "$offer->{name}: rate is not zero";
        cmp_ok $offer->{fraction}, '<=', 1,
            "$offer->{name}: rate is a fraction, not a percent or a dollar amount";
    }
};

done_testing;
