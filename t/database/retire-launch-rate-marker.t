#!/usr/bin/env perl
# ABOUTME: Retiring the launch_rate marker: no pricing plan names "the plan the platform sells" any more.
# ABOUTME: The platform's quoted rate comes from its current published Solo version, and the revert restores the keys.

use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use App::Sqitch;
use Test::PostgreSQL;
use Mojo::Pg;
use experimental 'signatures';

my $CHANGE = 'retire-launch-rate-marker';

my $pgsql = Test::PostgreSQL->new() or plan skip_all => $Test::PostgreSQL::errstr;
my $uri    = $pgsql->uri;
my $sqitch = App::Sqitch->new();

lives_ok { $sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', "$CHANGE^" ) }
    'deploy to the parent change succeeds';

my $db = Mojo::Pg->new($uri)->db;

sub plans () { $db->query(q{SELECT * FROM registry.pricing_plans ORDER BY id})->hashes->to_array }

# The platform's current published offers to tenants as signup read them at
# this change, in this schema's SQL: registry payment-processing versions with
# a percentage-of-sales plan, priced $0, not the platform's offer to itself.
# Today's reader reads tables later changes add.
sub offers_to_tenants () {
    return $db->query(q{
        SELECT o.name, v.price_cents AS amount_cents, p.fraction
          FROM registry.offer_versions v
          JOIN registry.offers o ON o.id = v.offer_id
          JOIN registry.resources r ON r.id = v.resource_id
          JOIN registry.offer_version_payment_plans p
            ON p.offer_version_id = v.id AND p.kind = 'percentage_of_sales'
         WHERE r.name = 'payment processing'
           AND v.published_at IS NOT NULL AND v.superseded_at IS NULL
           AND v.price_cents = 0
           AND NOT v.conditions @> '[{"kind": "holder_is_offerer"}]'
         ORDER BY p.fraction, o.name
    })->hashes->to_array;
}

sub marked () {
    $db->query(q{SELECT count(*) FROM registry.pricing_plans
                  WHERE jsonb_exists_any(metadata, array['launch_rate', 'display_order', 'featured'])})->array->[0];
}

ok marked(), 'the parent carries the launch_rate marker';

subtest 'no row carries the launch rate marker' => sub {
    my $before = plans();

    lives_ok { $sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', $CHANGE ) } 'the deploy runs';
    is marked(), 0, 'no pricing plan carries launch_rate, display_order or featured';

    my $solo = $db->query(q{
        SELECT p.fraction
          FROM registry.offers o
          JOIN registry.offer_versions v ON v.offer_id = o.id
          JOIN registry.offer_version_payment_plans p
            ON p.offer_version_id = v.id AND p.kind = 'percentage_of_sales'
         WHERE o.name = 'Solo' AND v.published_at IS NOT NULL AND v.superseded_at IS NULL
    })->array->[0];
    cmp_ok $solo, '==', 0.025, 'Solo is published at 2.5%';
    my $offers = offers_to_tenants();
    is scalar @$offers, 1, 'the platform offers exactly one version to tenants, so it quotes one rate';
    is $offers->[0]{fraction}, '0.025', 'the platform quotes the published Solo version\'s rate';

    lives_ok { $sqitch->run( 'sqitch', 'revert', '-t', $uri, '--to', "$CHANGE^", '-y' ) } 'the revert runs';
    is_deeply plans(), $before, 'the revert restores the stripped keys row by row';
};

done_testing;
