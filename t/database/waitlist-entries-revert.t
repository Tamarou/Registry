#!/usr/bin/env perl
# ABOUTME: waitlist-entries builds the queue in registry and every tenant, and a tenant cloned after deploy gets its own.
# ABOUTME: Reverting drops every copy, the cloned tenant's included, and the change redeploys.

use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use App::Sqitch;
use Capture::Tiny qw( capture );
use Test::PostgreSQL;
use Mojo::Pg;
use experimental 'signatures';

my $CHANGE = 'waitlist-entries';

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

# Schemas with a waitlist_entries table, and each copy's foreign-key targets'
# schemas, which must be its own.
sub queues () {
    return $db->query( q{
        SELECT t.table_schema || ':' || string_agg(DISTINCT f.relnamespace::regnamespace::text, ',')
          FROM information_schema.tables t
          JOIN pg_constraint c ON c.conrelid = format('%I.%I', t.table_schema, t.table_name)::regclass
           AND c.contype = 'f'
          JOIN pg_class f ON f.oid = c.confrelid
         WHERE t.table_name = 'waitlist_entries'
         GROUP BY t.table_schema ORDER BY 1
    } )->arrays->flatten->to_array;
}

provision('early');
lives_ok { sqitch( 'deploy', '-t', $uri, '--to', $CHANGE ) } 'deploy to the change succeeds';
provision('late');

is_deeply queues(), [qw( early:early late:late registry:registry )],
    'every schema has its own queue, referring only to its own tables';

my $late = $db->query( q{
    SELECT indexdef FROM pg_indexes WHERE schemaname = 'late' AND indexname = 'waitlist_entries_resource_id_family_member_id_idx'
} )->array;
like $late && $late->[0], qr/WHERE \(state = ANY/, 'the cloned tenant keeps the one-live-entry-per-child index';

lives_ok { sqitch( 'revert', '-t', $uri, '--to', "$CHANGE^", '-y' ) } 'the revert runs';
is_deeply queues(), [], 'no queue is left in any schema';

lives_ok { sqitch( 'deploy', '-t', $uri, '--to', $CHANGE ) } 'the redeploy runs';

done_testing;
