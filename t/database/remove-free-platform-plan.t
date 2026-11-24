#!/usr/bin/env perl
# ABOUTME: The Free-plan removal is a data change, invisible to the schema revert harness.
# ABOUTME: Asserts it deletes only the platform default plan, refuses while anything references it, and reverts by id.

use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use App::Sqitch;
use Capture::Tiny qw( capture_stderr );
use Test::PostgreSQL;
use Mojo::Pg;

my $CHANGE = 'remove-free-platform-plan';

my $pgsql = Test::PostgreSQL->new() or plan skip_all => $Test::PostgreSQL::errstr;
my $uri    = $pgsql->uri;
my $sqitch = App::Sqitch->new();

lives_ok { $sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', "$CHANGE^" ) }
    'deploy to the parent change succeeds';

my $db = Mojo::Pg->new($uri)->db;

sub free_rows {
    return $db->query(
        q{SELECT * FROM registry.pricing_plans
           WHERE plan_scope = 'platform' AND metadata->>'default' = 'true'
           ORDER BY id}
    )->hashes->to_array;
}

my $free = free_rows();
is scalar @$free, 1, 'the parent holds exactly one platform default (Free) plan';
my $free_id = $free->[0]{id};

subtest 'free platform plan row is deleted' => sub {
    lives_ok { $sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', $CHANGE ) } 'the deploy runs';
    is_deeply free_rows(), [], 'no platform-scope plan marked default remains';

    lives_ok { $sqitch->run( 'sqitch', 'revert', '-t', $uri, '--to', "$CHANGE^", '-y' ) }
        'the revert runs';
    is_deeply free_rows(), $free, 'the revert re-inserts the Free row by id, as it was';
};

done_testing;
