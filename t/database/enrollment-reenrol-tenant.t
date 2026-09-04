#!/usr/bin/env perl
# ABOUTME: The re-enrolment fix reaches a cloned tenant schema, behaviourally.
# ABOUTME: The deploy calls tenants "the half of this table that matters"; nothing tested it.
use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use Test::PostgreSQL;
use Mojo::Pg;
use Test::Registry::DB ();

# The bug this migration removes lived in create_for_payment, which runs against
# whatever schema the DAO is pointed at. Every other test for it runs in
# registry -- and the deploy's own comment says the tenant copy is "the schemas
# that hold the customer money". A verify that searched tenants by the registry
# constraint name passed while the bug was still live in exactly those schemas,
# because nothing ever ran the re-enrolment against a cloned one.

my $pgsql = Test::PostgreSQL->new() or plan skip_all => $Test::PostgreSQL::errstr;
my $uri   = $pgsql->uri;

sub deploy_to ($target) {
    system( "sqitch deploy -t '$uri' --to '$target' >/dev/null 2>&1" ) == 0
        or die "sqitch deploy --to $target failed\n";
}

my $CHANGE = 'enrollment-reenrol-after-drop';

# A tenant provisioned BEFORE the change, which is the provenance that carries
# the Postgres-generated constraint name.
deploy_to("$CHANGE^");
my $db = Mojo::Pg->new($uri)->search_path(['registry','public'])->db;
my $slug = "rt$$";
$db->query('INSERT INTO registry.tenants (name, slug) VALUES (?, ?)', "RT $$", $slug);
$db->query('SELECT registry.clone_schema(?)', $slug);

my $before = $db->query(q{
    SELECT c.relname FROM pg_index i
      JOIN pg_class c ON c.oid = i.indexrelid
      JOIN pg_class t ON t.oid = i.indrelid
      JOIN pg_namespace n ON n.oid = t.relnamespace
     WHERE n.nspname = ? AND t.relname = 'enrollments'
       AND i.indisunique AND i.indpred IS NULL
       AND ( SELECT array_agg(a.attname::text ORDER BY a.attname::text)
               FROM unnest(i.indkey) k
               JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k )
           = ARRAY['session_id','student_id','student_type']}, $slug)->arrays->flatten->to_array;
ok scalar @$before, 'the cloned tenant starts with a total uniqueness rule'
    or diag 'nothing to remove -- the fixture proves nothing';
diag "  tenant's rule is named: @$before";

deploy_to($CHANGE);

subtest 'the total rule is gone from the tenant, whatever it was called' => sub {
    my $total = $db->query(q{
        SELECT count(*) FROM pg_index i
          JOIN pg_class t ON t.oid = i.indrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
         WHERE n.nspname = ? AND t.relname = 'enrollments'
           AND i.indisunique AND i.indpred IS NULL
           AND ( SELECT array_agg(a.attname::text ORDER BY a.attname::text)
                   FROM unnest(i.indkey) k
                   JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k )
               = ARRAY['session_id','student_id','student_type']}, $slug)->array->[0];
    is $total, 0, 'no total rule survives in the tenant';
};

# The behaviour, not the schema. This is what nothing tested.
subtest 'a dropped child can re-enrol in the tenant schema' => sub {
    my $tdb = Mojo::Pg->new($uri)->search_path([$slug, 'public'])->db;

    my $uid = $tdb->query(
        'INSERT INTO users (username) VALUES (?) RETURNING id', "rt_u_$$")->hash->{id};
    my $sid = $tdb->query(
        q{INSERT INTO sessions (name, slug, status, capacity, metadata)
          VALUES (?, ?, 'published', 10, '{}'::jsonb) RETURNING id},
        "RT S $$", "rt_s_$$")->hash->{id};
    my $kid = "11111111-2222-3333-4444-555555555555";

    my $insert = sub ($status) {
        $tdb->query(q{INSERT INTO enrollments
            (session_id, student_id, student_type, parent_id, status)
            VALUES (?, ?, 'family_member', ?, ?) RETURNING id},
            $sid, $kid, $uid, $status)->hash->{id};
    };

    my $first = $insert->('active');
    ok $first, 'the child enrols';

    $tdb->query('UPDATE enrollments SET status = ? WHERE id = ?', 'cancelled', $first);

    my $err = do { local $@; eval { $insert->('active'); 1 }; $@ };
    is $err, '', 'and can re-enrol after dropping -- in the TENANT schema';

    my $live = $tdb->query(q{SELECT COUNT(*) FROM enrollments
         WHERE session_id = ? AND student_id = ? AND status <> 'cancelled'},
        $sid, $kid)->array->[0];
    is $live, 1, 'holding exactly one live seat';

    my $dup = do { local $@; eval { $insert->('active'); 1 }; $@ };
    like $dup, qr/duplicate key/,
        'while a second LIVE seat is still refused in the tenant';
};

done_testing;
