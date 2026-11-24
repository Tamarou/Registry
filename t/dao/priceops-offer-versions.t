#!/usr/bin/env perl
# ABOUTME: Resources, offers and their append-only versions, immutable once published.
# ABOUTME: The database enforces immutability, so raw SQL is held to it as much as the DAO.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use Test::Registry::DB;
use Test::Registry::Offers qw( offer_terms );
use Mojo::Pg;
use POSIX ();
use Registry::DAO::Resource;
use Registry::DAO::Offer;
use Registry::DAO::OfferVersion;
use Registry::DAO::Tenant;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

subtest 'finite and unbounded resources round trip' => sub {
    my $seats = Registry::DAO::Resource->create( $db,
        { name => 'Seats in Tuesday wheel', kind => 'finite', capacity => 10 } );
    my $email = Registry::DAO::Resource->create( $db,
        { name => 'Email sending', kind => 'unbounded' } );

    my $s = Registry::DAO::Resource->find( $db, { id => $seats->id } );
    is $s->name,     'Seats in Tuesday wheel', 'finite resource keeps its name';
    is $s->kind,     'finite',                 'and its kind';
    is $s->capacity, 10,                       'and its capacity';

    my $e = Registry::DAO::Resource->find( $db, { id => $email->id } );
    is $e->kind, 'unbounded', 'unbounded resource keeps its kind';
    ok !defined $e->capacity, 'and stores no capacity';
};

my $seat = Registry::DAO::Resource->create( $db,
    { name => 'Seat', kind => 'finite', capacity => 8 } );
my $clay = Registry::DAO::Resource->create( $db,
    { name => 'Clay', kind => 'unbounded' } );

subtest 'publishing appends a version and supersedes the last' => sub {
    my $offer = Registry::DAO::Offer->create( $db, { name => 'Drop-in wheel' } );

    my $v1 = $offer->draft( $db, offer_terms( $clay->id ) );
    is $v1->version, 1, 'the first draft is version 1';
    ok !$v1->is_published, 'and is a draft';
    ok !$offer->current_version($db), 'an offer with only a draft has no current version';

    $v1 = $v1->update( $db, { resource_id => $seat->id } );
    is $v1->resource_id, $seat->id, 'a draft can be edited';

    $v1 = $v1->publish($db);
    ok $v1->is_published, 'publishing marks the version published';
    is $offer->current_version($db)->id, $v1->id, 'and makes it current';

    my $v2 = $offer->draft( $db, offer_terms( $seat->id ) );
    is $v2->version, 2, 'the next draft is version 2';
    is $offer->current_version($db)->id, $v1->id, 'a draft does not replace the current version';

    $v2->publish($db);
    is $offer->current_version($db)->id, $v2->id, 'publishing version 2 makes it current';
    ok defined Registry::DAO::OfferVersion->find( $db, { id => $v1->id } )->superseded_at,
        'and supersedes version 1';
    is_deeply [ map { $_->version } $offer->versions($db)->@* ], [ 1, 2 ],
        'both versions are kept, in order';

    my $current = $db->query(
        'SELECT count(*) FROM offer_versions
          WHERE offer_id = ? AND published_at IS NOT NULL AND superseded_at IS NULL',
        $offer->id )->array->[0];
    is $current, 1, 'exactly one published version is current';
};

# An offer whose version 1 is published; returns the offer and that version.
sub published_offer ( $name, $handle = $db ) {
    my $offer = Registry::DAO::Offer->create( $handle, { name => $name } );
    return ( $offer, $offer->draft( $handle, offer_terms( $seat->id ) )->publish($handle) );
}

subtest 'published version terms refused by the database' => sub {
    my ( $offer, $v1 ) = published_offer('Six-week course');
    my $names = qr/offer \Q@{[ $offer->id ]}\E version 1/;

    throws_ok {
        $db->query( 'UPDATE offer_versions SET resource_id = ? WHERE id = ?', $clay->id, $v1->id )
    } $names, 'changing the resource of a published version is refused, naming offer and version';
    throws_ok {
        $db->query( 'UPDATE offer_versions SET version = 7 WHERE id = ?', $v1->id )
    } $names, 'renumbering a published version is refused';
    throws_ok {
        $db->query( 'UPDATE offer_versions SET created_at = now() - interval \'1 day\' WHERE id = ?', $v1->id )
    } $names, 'every column but the superseded marker is protected';

    lives_ok {
        $db->query( 'UPDATE offer_versions SET superseded_at = now() WHERE id = ?', $v1->id )
    } 'setting only the superseded marker is allowed';

    my $draft = $offer->draft( $db, offer_terms( $seat->id ) );
    lives_ok {
        $db->query( 'UPDATE offer_versions SET resource_id = ? WHERE id = ?', $clay->id, $draft->id )
    } 'a draft stays editable by raw SQL';
};

subtest 'added column is protected without trigger change' => sub {
    my ( $offer, $v1 ) = published_offer('Couples night');
    my $draft = $offer->draft( $db, offer_terms( $seat->id ) );

    my $tx = $db->begin;    # rolled back on scope exit: the column is the test's own
    $db->query('ALTER TABLE offer_versions ADD COLUMN test_note text');
    lives_ok {
        $db->query( q{UPDATE offer_versions SET test_note = 'x' WHERE id = ?}, $draft->id )
    } 'the new column is editable on a draft';
    throws_ok {
        $db->query( q{UPDATE offer_versions SET test_note = 'x' WHERE id = ?}, $v1->id )
    } qr/offer \Q@{[ $offer->id ]}\E version 1/, 'and refused on a published version';
};

# A tenant provisioned the way signup provisions one: the row, then its schema.
sub new_tenant ($slug) {
    my $tenant = Registry::DAO::Tenant->create( $db, { name => "Studio $slug", slug => $slug } );
    $db->query( 'SELECT clone_schema(dest_schema => ?)', $slug );
    return $tenant->dao($dao)->db;
}

subtest 'new tenant schema has offer tables and triggers' => sub {
    my $tdb = new_tenant('clay_corner');
    is $tdb->query('SHOW search_path')->array->[0], 'clay_corner, public',
        'the tenant connection is scoped to its own schema';

    my $res = Registry::DAO::Resource->create( $tdb,
        { name => 'Wheel', kind => 'finite', capacity => 4 } );
    my $offer = Registry::DAO::Offer->create( $tdb, { name => 'Taster' } );
    my $v1 = $offer->draft( $tdb, offer_terms( $res->id ) )->publish($tdb);
    ok $v1->is_published, 'an offer is published in the tenant schema';

    throws_ok {
        $tdb->query( 'UPDATE offer_versions SET version = 9 WHERE id = ?', $v1->id )
    } qr/offer \Q@{[ $offer->id ]}\E version 1/, 'and its published terms are refused there too';

    my $crossing = $db->query(q{
        SELECT c.conname
          FROM pg_constraint c
          JOIN pg_class t ON t.oid = c.conrelid
          JOIN pg_class r ON r.oid = c.confrelid
         WHERE c.contype = 'f'
           AND t.relname IN ('resources', 'offers', 'offer_versions')
           AND t.relnamespace <> r.relnamespace
    })->arrays->map( sub { $_->[0] } )->to_array;
    is_deeply $crossing, [], 'no foreign key on these tables names another schema';

    my $fks = $db->query(q{
        SELECT count(*) FROM pg_constraint c
          JOIN pg_class t ON t.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
         WHERE c.contype = 'f' AND t.relname = 'offer_versions' AND n.nspname = 'clay_corner'
    })->array->[0];
    is $fks, 3, 'and the tenant copy keeps its own foreign keys: offer, resource and class';
};

subtest 'published version delete refused' => sub {
    my ( $offer, $v1 ) = published_offer('Glaze night');
    throws_ok {
        $db->query( 'DELETE FROM offer_versions WHERE id = ?', $v1->id )
    } qr/offer \Q@{[ $offer->id ]}\E version 1/, 'deleting a published version is refused';
    ok Registry::DAO::OfferVersion->find( $db, { id => $v1->id } ), 'and the version is still there';

    my $draft = $offer->draft( $db, offer_terms( $seat->id ) );
    lives_ok { $db->query( 'DELETE FROM offer_versions WHERE id = ?', $draft->id ) }
        'a draft, never sold under, can still be discarded';
};

subtest 'unpublishing refused by the database' => sub {
    my ( $offer, $v1 ) = published_offer('Kids clay');
    my $names = qr/offer \Q@{[ $offer->id ]}\E version 1/;
    throws_ok {
        $db->query( 'UPDATE offer_versions SET published_at = NULL WHERE id = ?', $v1->id )
    } $names, 'setting a published version back to draft is refused';

    $offer->draft( $db, offer_terms( $seat->id ) )->publish($db);
    throws_ok {
        $db->query( 'UPDATE offer_versions SET superseded_at = NULL WHERE id = ?', $v1->id )
    } $names, 'clearing the superseded marker while its successor is current is refused';
    throws_ok {
        $db->query( q{UPDATE offer_versions SET superseded_at = now() + interval '1 day' WHERE id = ?}, $v1->id )
    } $names, 'and so is moving it: once superseded is final';
};

subtest 'duplicate version number refused' => sub {
    my ( $offer, $v1 ) = published_offer('Raku firing');
    throws_ok {
        $db->query( 'INSERT INTO offer_versions (offer_id, version, resource_id, price_cents, units_per_acceptance, per_booking_cap)
                  VALUES (?, 1, ?, 0, 1, 1)',
            $offer->id, $seat->id )
    } qr/offer_versions_offer_version_key/, 'a second version 1 for the same offer is refused';
};

subtest 'invalid resource capacity refused' => sub {
    for my $case (
        [ { name => 'r', kind => 'finite' },                        'a finite resource with no capacity' ],
        [ { name => 'r', kind => 'finite', capacity => -1 },        'a finite resource with a negative capacity' ],
        [ { name => 'r', kind => 'unbounded', capacity => 5 },      'an unbounded resource given a capacity' ],
        [ { name => 'r', kind => 'sometimes' },                     'an unknown kind' ],
    ) {
        throws_ok { $db->insert( 'resources', $case->[0] ) } qr/violates check constraint/,
            "$case->[1] is refused";
    }
};

subtest 'concurrent publishes leave one current version' => sub {
    my ( $offer, $v1 ) = published_offer('Wheel throwing');
    my $uri = $test_db->uri;

    # Two real connections and a fork: one connection cannot interleave with
    # itself. A holds its publish open; B starts its own and must wait for it.
    pipe( my $child_reads, my $parent_writes ) or die "pipe: $!";
    my $pid = fork() // die "fork: $!";
    unless ($pid) {
        close $parent_writes;
        readline $child_reads;
        my $pg  = Mojo::Pg->new($uri)->search_path( [ 'registry', 'public' ] );
        my $bdb = $pg->db;
        my $ok  = eval {
            Registry::DAO::OfferVersion->draft( $bdb, $offer->id, offer_terms( $seat->id ) )
                ->publish($bdb);
            1;
        };
        print STDERR "child publish failed: $@" unless $ok;
        POSIX::_exit( $ok ? 0 : 1 );
    }

    close $child_reads;
    my $pg  = Mojo::Pg->new($uri)->search_path( [ 'registry', 'public' ] );
    my $adb = $pg->db;
    my $tx  = $adb->begin;
    Registry::DAO::OfferVersion->draft( $adb, $offer->id, offer_terms( $seat->id ) )->publish($adb);
    print $parent_writes "go\n";
    $parent_writes->flush;
    sleep 1;    # let B reach the offer and block behind A
    $tx->commit;
    waitpid $pid, 0;

    is $? >> 8, 0, 'the second publish waits for the first and then succeeds';
    is_deeply [ map { $_->version } $offer->versions($db)->@* ], [ 1, 2, 3 ],
        'each publish got its own version number';
    my $current = $db->query(
        'SELECT array_agg(version) FROM offer_versions
          WHERE offer_id = ? AND published_at IS NOT NULL AND superseded_at IS NULL',
        $offer->id )->array->[0];
    is_deeply $current, [3], 'and exactly one version, the last, is current';
};

subtest 'cross schema resource reference refused' => sub {
    my $adb = new_tenant('studio_a');
    my $bdb = new_tenant('studio_b');
    my $b_only = Registry::DAO::Resource->create( $bdb, { name => 'B wheel', kind => 'finite', capacity => 2 } );
    my $offer  = Registry::DAO::Offer->create( $adb, { name => 'A taster' } );

    throws_ok { $offer->draft( $adb, offer_terms( $b_only->id ) ) }
        qr/offer_versions_resource_id_fkey/,
        "tenant A's offer version cannot name a resource that only tenant B has";
};

subtest 'tenant connection never reads another tenants offers' => sub {
    my $adb = new_tenant('studio_c');
    my $bdb = new_tenant('studio_d');
    my $res = Registry::DAO::Resource->create( $adb, { name => 'C wheel', kind => 'finite', capacity => 2 } );
    my $offer = Registry::DAO::Offer->create( $adb, { name => 'C taster' } );
    my $v1 = $offer->draft( $adb, offer_terms( $res->id ) )->publish($adb);

    ok !Registry::DAO::Offer->find( $bdb, { id => $offer->id } ), "B cannot find A's offer by id";
    ok !Registry::DAO::OfferVersion->find( $bdb, { id => $v1->id } ), "nor A's offer version";
    is_deeply [ Registry::DAO::Offer->find($bdb) ], [], 'B lists no offers at all';
    ok !Registry::DAO::Offer->find( $db, { id => $offer->id } ), 'nor does the registry schema';
};

done_testing;
