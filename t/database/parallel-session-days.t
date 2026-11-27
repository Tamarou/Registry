#!/usr/bin/env perl
# ABOUTME: parallel-session-days: two sessions of one program may share a location and start, in every schema.
# ABOUTME: Other events keep one per program, location and time; the revert refuses by schema while parallel days exist.

use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use App::Sqitch;
use Capture::Tiny qw( capture );
use Test::PostgreSQL;
use Mojo::Pg;
use experimental 'signatures';

my $CHANGE = 'parallel-session-days';

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

# In $schema: a program, a location, a teacher, and $n events at one
# instant, each a day of its own session when $sessions, else plain events.
sub same_slot ( $schema, $n, $sessions ) {
    my $q  = sub ($sql) { $sql =~ s/\bS\./"$schema"./gr };
    my $pid = $db->query( $q->(q{INSERT INTO S.projects (name, slug) VALUES ('Camp', 'camp') RETURNING id}) )->array->[0];
    my $lid = $db->query( $q->(q{INSERT INTO S.locations (name, slug, time_zone) VALUES ('Field', 'field', 'UTC') RETURNING id}) )->array->[0];
    my $uid = $db->query( $q->(q{INSERT INTO S.users (username) VALUES ('teach') RETURNING id}) )->array->[0];
    for my $i ( 1 .. $n ) {
        my $rid = $sessions
            ? $db->query( $q->(q{INSERT INTO S.resources (name, kind, capacity) VALUES (?, 'finite', 5) RETURNING id}), "Group $i" )
                ->array->[0]
            : undef;
        $db->query( $q->(q{
            INSERT INTO S.events (project_id, location_id, teacher_id, time, duration, session_resource_id)
            VALUES (?, ?, ?, '2027-06-07 13:00+00', 60, ?)
        }), $pid, $lid, $uid, $rid );
    }
}

provision('early');
lives_ok { sqitch( 'deploy', '-t', $uri, '--to', $CHANGE ) } 'deploy to the change succeeds';
provision('late');

# Each check in its own transaction, rolled back as it goes out of scope.
for my $schema (qw( registry early late )) {
    subtest "in $schema" => sub {
        lives_ok { my $tx = $db->begin; same_slot( $schema, 2, 1 ) }
            'two sessions\' days may share a program, location and start';
        throws_ok { my $tx = $db->begin; same_slot( $schema, 2, 0 ) } qr/duplicate key/, 'two plain events still may not';
        throws_ok {
            my $tx = $db->begin;
            same_slot( $schema, 1, 1 );
            $db->query( qq{INSERT INTO "$schema".events (project_id, location_id, teacher_id, time, duration, session_resource_id)
                           SELECT project_id, location_id, teacher_id, time, duration, session_resource_id FROM "$schema".events} );
        } qr/duplicate key/, 'and a session may not have two days at one instant';
    };
}

subtest 'the revert refuses while parallel session days exist, naming the schema' => sub {
    same_slot( 'late', 2, 1 );
    throws_ok { sqitch( 'revert', '-t', $uri, '--to', "$CHANGE^", '-y' ) } qr/late.*parallel session days|parallel session days.*late/,
        'refused by name';
    $db->query(qq{DELETE FROM late.$_}) for qw( session_events events );
};

subtest 'the revert restores the old key everywhere, including a tenant cloned after deploy' => sub {
    lives_ok { sqitch( 'revert', '-t', $uri, '--to', "$CHANGE^", '-y' ) } 'the revert runs';
    is_deeply $db->query( q{
        SELECT n.nspname FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
         WHERE t.relname = 'events' AND c.conname = 'events_project_id_location_id_time_key' ORDER BY 1
    } )->arrays->flatten->to_array, [qw( early late registry )], 'every schema has the old key';
    is_deeply $db->query( q{
        SELECT schemaname || '.' || indexname FROM pg_indexes
         WHERE tablename = 'events' AND (indexdef LIKE '%WHERE%' OR indexdef LIKE '%(session_resource_id, "time")%')
    } )->arrays->flatten->to_array, [], 'and no partial or session-day key is left';
    lives_ok { sqitch( 'deploy', '-t', $uri, '--to', $CHANGE ) } 'the redeploy runs';
};

done_testing;
