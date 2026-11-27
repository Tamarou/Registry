#!/usr/bin/env perl
# ABOUTME: entitlement-uses-per-day backfills each use's day, and reverts cleanly, including in a tenant cloned after deploy.
# ABOUTME: The revert keeps present occurrence uses only: absences and session days have no row in the old key.

use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use App::Sqitch;
use Capture::Tiny qw( capture );
use Test::PostgreSQL;
use Mojo::Pg;
use experimental 'signatures';

my $CHANGE = 'entitlement-uses-per-day';

my $pgsql = Test::PostgreSQL->new() or plan skip_all => $Test::PostgreSQL::errstr;
my $uri   = $pgsql->uri;

# Sqitch's exception says only that psql failed; the migration's message is on stderr.
sub sqitch (@args) {
    my ( undef, $err, $ok ) = capture { eval { App::Sqitch->new->run( 'sqitch', @args ); 1 } };
    die $err unless $ok;
}

lives_ok { sqitch( 'deploy', '-t', $uri, '--to', "$CHANGE^" ) } 'deploy to the parent succeeds';
my $pg = Mojo::Pg->new($uri);
my $db = $pg->db;

sub provision ($slug) {
    $db->query( 'INSERT INTO registry.tenants (name, slug) VALUES (?, ?)', $slug, $slug );
    $db->query( 'SELECT registry.clone_schema(dest_schema => ?)', $slug );
}

sub id ( $table, %row ) { $db->insert( "registry.$table", \%row, { returning => 'id' } )->hash->{id} }

# The key columns of each schema's entitlement_uses.
sub keys_by_schema () {
    return { map { @$_ } $db->query( q{
        SELECT n.nspname, string_agg(a.attname, ',' ORDER BY a.attnum)
          FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
          JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY (c.conkey)
         WHERE c.contype = 'p' AND t.relname = 'entitlement_uses'
         GROUP BY n.nspname
    } )->arrays->each };
}

my $entitlement = $db->query('SELECT id FROM registry.entitlements LIMIT 1')->array->[0]
    or BAIL_OUT 'registry has no entitlement to mark';
my $teacher  = id( users    => username => 'per-day-teacher' );
my $project  = id( projects => name => 'Per day', slug => 'per-day' );
my $location = id( locations => name => 'Per day room', slug => 'per-day-room', time_zone => 'UTC' );
my $event    = sub ($day) {
    id( events => project_id => $project, location_id => $location, teacher_id => $teacher,
        time => "2027-06-0$day 13:00:00Z", duration => 60 );
};
my $occurrence_day = $event->(1);
my $occurrence = id( resources => name => 'Per day occurrence', kind => 'finite', capacity => 4,
    event_id => $occurrence_day );
$db->insert( 'registry.entitlement_uses', { entitlement_id => $entitlement, occurrence_id => $occurrence } );

provision('early');
lives_ok { sqitch( 'deploy', '-t', $uri, '--to', $CHANGE ) } 'deploy to the change succeeds';
provision('late');

is_deeply $db->select( 'registry.entitlement_uses', [qw( event_id mark )] )->hashes->to_array,
    [ { event_id => $occurrence_day, mark => 'present' } ], "a use so far is present on its occurrence's event";
is_deeply keys_by_schema(), { map { $_ => 'entitlement_id,event_id' } qw( registry early late ) },
    'every schema is keyed per day, the tenant cloned after deploy too';

my $session = id( resources => name => 'Per day session', kind => 'finite', capacity => 4 );
my @days    = map { $event->($_) } 2 .. 4;
$db->update( 'registry.events', { session_resource_id => $session }, { id => \@days } );
$db->insert( 'registry.entitlement_uses', {
    entitlement_id => $entitlement, occurrence_id => $session, event_id => $days[$_], mark => $_ ? 'present' : 'absent',
} ) for 0 .. 2;

lives_ok { sqitch( 'revert', '-t', $uri, '--to', "$CHANGE^", '-y' ) } 'the revert runs';
is_deeply keys_by_schema(), { map { $_ => 'entitlement_id,occurrence_id' } qw( registry early late ) },
    'every schema is keyed per occurrence again';
is_deeply $db->select( 'registry.entitlement_uses', 'occurrence_id' )->arrays->flatten->to_array,
    [$occurrence], 'the occurrence use stays; the session days\' marks go';

lives_ok { sqitch( 'deploy', '-t', $uri, '--to', $CHANGE ) } 'the redeploy runs';

done_testing;
