#!/usr/bin/env perl
# ABOUTME: Reverting session-resources removes its day guard everywhere, including from a tenant cloned after deploy.
# ABOUTME: clone_schema copies registry's functions into each new tenant, so the revert must drop those copies too.

use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use App::Sqitch;
use Capture::Tiny qw( capture );
use Test::PostgreSQL;
use Mojo::Pg;
use experimental 'signatures';

my $CHANGE = 'session-resources';
my $GUARD  = 'session_day_has_no_occurrence';

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

sub guards () {
    return {
        functions => $db->query( q{
            SELECT n.nspname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE p.proname = ? ORDER BY 1
        }, $GUARD )->arrays->flatten->to_array,
        triggers => $db->query( q{
            SELECT n.nspname || '.' || c.relname FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
              JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE p.proname = ? ORDER BY 1
        }, $GUARD )->arrays->flatten->to_array,
    };
}

provision('early');
lives_ok { sqitch( 'deploy', '-t', $uri, '--to', $CHANGE ) } 'deploy to the change succeeds';
provision('late');

my $deployed = guards();
ok( ( grep { $_ eq 'late' } $deployed->{functions}->@* ), 'the tenant cloned after deploy has its own guard copy' );
is scalar $deployed->{triggers}->@*, 6, 'and every schema has both guard triggers';

lives_ok { sqitch( 'revert', '-t', $uri, '--to', "$CHANGE^", '-y' ) } 'the revert runs';
is_deeply guards(), { functions => [], triggers => [] }, 'no guard function or trigger is left in any schema';

lives_ok { sqitch( 'deploy', '-t', $uri, '--to', $CHANGE ) } 'the redeploy runs';

done_testing;
