#!/usr/bin/env perl
# ABOUTME: Reverting instalment-payment-plans removes its columns and missed_payment trigger everywhere,
# ABOUTME: including from a tenant cloned after deploy, whose copy of the trigger function clone_schema made.

use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use App::Sqitch;
use Capture::Tiny qw( capture );
use Test::PostgreSQL;
use Mojo::Pg;
use experimental 'signatures';

my $CHANGE = 'instalment-payment-plans';
my $GUARD   = 'offer_version_instalments_need_missed_payment';
my $TRIGGER = q{offer_versions_instalments_need_missed_payment};

my $pgsql = Test::PostgreSQL->new() or plan skip_all => $Test::PostgreSQL::errstr;
my $uri   = $pgsql->uri;

# Sqitch's exception says only that psql failed; the migration's message is on stderr.
sub sqitch (@args) {
    my ( undef, $err, $ok ) = capture { eval { App::Sqitch->new->run( 'sqitch', @args ); 1 } };
    die $err unless $ok;
}

lives_ok { sqitch( 'deploy', '-t', $uri, '--to', "$CHANGE^" ) } 'deploy to the parent succeeds';
my $db = Mojo::Pg->new($uri)->db;

sub provision ($slug) {
    $db->query( 'INSERT INTO registry.tenants (name, slug) VALUES (?, ?)', $slug, $slug );
    $db->query( 'SELECT registry.clone_schema(dest_schema => ?)', $slug );
}

sub left_behind () {
    return {
        functions => $db->query( q{
            SELECT n.nspname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE p.proname = ? ORDER BY 1
        }, $GUARD )->arrays->flatten->to_array,
        triggers => $db->query( q{
            SELECT n.nspname FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
              JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE t.tgname = ? ORDER BY 1
        }, $TRIGGER )->arrays->flatten->to_array,
        columns => $db->query( q{
            SELECT table_schema FROM information_schema.columns
             WHERE table_name = 'offer_version_payment_plans' AND column_name = 'cadence' ORDER BY 1
        } )->arrays->flatten->to_array,
    };
}

provision('early');
lives_ok { sqitch( 'deploy', '-t', $uri, '--to', $CHANGE ) } 'deploy to the change succeeds';
provision('late');

my $deployed = left_behind();
ok( ( grep { $_ eq 'late' } $deployed->{functions}->@* ), 'the tenant cloned after deploy has its own function copy' );
is_deeply $deployed->{triggers}, [qw( early late registry )], 'every schema has the trigger';
is_deeply $deployed->{columns},  [qw( early late registry )], 'and the instalment columns';

lives_ok { sqitch( 'revert', '-t', $uri, '--to', "$CHANGE^", '-y' ) } 'the revert runs';
is_deeply left_behind(), { functions => [], triggers => [], columns => [] },
    'no function, trigger or instalment column is left in any schema';

lives_ok { sqitch( 'deploy', '-t', $uri, '--to', $CHANGE ) } 'the redeploy runs';

done_testing;
