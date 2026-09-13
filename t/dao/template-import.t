#!/usr/bin/env perl
# ABOUTME: Grades what `registry template import` does to a row that already exists.
# ABOUTME: Files carry an untouched row forward; a customised one is left alone.

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO;
use Registry::DAO::Template;
use Mojo::Home;
use Mojo::Util ();
use Digest::SHA qw( sha256_hex );
use Encode qw( encode );

# The same normalisation import_from_file uses, restated here rather than
# reached into: if the test agreed with the implementation by construction it
# could not catch the implementation being wrong, which is exactly what
# happened -- stamps were written from bytes and compared against characters.
sub sha_of ($text) { sha256_hex( encode( 'UTF-8', $text ) ) }

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

# A real file under templates/: import_from_file derives the template name from
# the path relative to that directory via $file->to_rel('templates'), which
# resolves against the process's cwd, so a fixture written elsewhere would be
# named something else entirely.
my $file = Mojo::Home->new->child('templates/tenant-signup/pricing.html.ep');
ok -f $file, 'the fixture file exists' or BAIL_OUT "$file is missing";
# Decoded, because that is what the database should hold: slurp gives bytes,
# and storing those directly is what double-encoded every non-ASCII glyph.
my $on_disk = Mojo::Util::decode( 'UTF-8', $file->slurp );

subtest 'an absent template is created from its file, and stamped' => sub {
    my $template = Registry::DAO::Template->import_from_file( $dao, $file );
    ok $template, 'import returns a template';
    is $template->name, 'tenant-signup/pricing', 'named from the file path';
    is $template->content, $on_disk, 'content is the file';
    ok $template->metadata->{imported_sha256},
        'and it records what import wrote, so a later edit is detectable';
};

# The defect in #352. Production's row for this name was written 2026-03-22 and
# never moved again: the file changed in #346, the row did not, and the signup
# page rendered three pricing tiers with no rate for six months. `registry
# template import registry` runs on every web boot and was a no-op for every
# name already present.
#
# Such a row carries no stamp, which is exactly the bootstrap case: unstamped
# means "predates this mechanism", and the file is allowed to carry it forward.
subtest 'an unstamped drifted row is reconciled with its file' => sub {
    $db->update( 'templates',
        { content => '<p>six months stale</p>', metadata => { -json => {} } },
        { name    => 'tenant-signup/pricing' } );

    my $before = Registry::DAO::Template->find( $db, { name => 'tenant-signup/pricing' } );
    is $before->content, '<p>six months stale</p>', 'drifted, and unstamped';

    Registry::DAO::Template->import_from_file( $dao, $file );

    my $after = Registry::DAO::Template->find( $db, { name => 'tenant-signup/pricing' } );
    is $after->content, $on_disk, 'import writes the file over it';
    is $after->id, $before->id, 'in place, rather than inserting beside it';
    ok $after->metadata->{imported_sha256}, 'and stamps it on the way through';
};

# The defect that made the first release freeze every row it wrote. The stamp
# was computed from Mojo::File->slurp's BYTES while the value read back is a
# character string, so they hashed differently by construction: on the next
# import every stamped row looked customised and was skipped for good.
subtest 'a stamp still matches after a database round-trip' => sub {
    my $row = Registry::DAO::Template->find( $db, { name => 'tenant-signup/pricing' } );

    is $row->metadata->{imported_sha256}, sha_of( $row->content ),
        'the stamp equals the hash of what the database gives back';
};

# The file has a checkmark and an arrow. Handing slurp's bytes to DBD::Pg makes
# it read them as Latin-1 and re-encode, so the glyph arrives mangled -- which
# is why the deployed pricing page showed mojibake for months after #346 fixed
# the file.
subtest 'content is stored as characters, not double-encoded bytes' => sub {
    my $row = Registry::DAO::Template->find( $db, { name => 'tenant-signup/pricing' } );

    like $row->content, qr/\x{2713}/, 'the checkmark survives the round-trip';
    unlike $row->content, qr/\x{00E2}\x{0153}|\x{00E2}\x{20AC}/,
        'and no double-encoded sequence appears in its place';
};

# A stamped row whose content still matches its stamp is unmodified, so a
# CHANGED file must still carry it forward. Nothing covered this, which is how
# the round-trip defect shipped.
subtest 'a stamped but unmodified row still follows the file' => sub {
    my $row = Registry::DAO::Template->find( $db, { name => 'tenant-signup/pricing' } );

    # Stand in for "the file changed since this row was written": leave the row
    # internally consistent -- content and stamp agree -- but different from disk.
    my $old = '<p>what the previous release shipped</p>';
    $db->update( 'templates',
        { content  => $old,
          metadata => { -json => { imported_sha256 => sha_of($old) } } },
        { id => $row->id } );

    Registry::DAO::Template->import_from_file( $dao, $file );

    my $after = Registry::DAO::Template->find( $db, { id => $row->id } );
    isnt $after->content, $old, 'the row is not left behind at the old content';
    is $after->metadata->{imported_sha256}, sha_of( $after->content ),
        'and its stamp tracks what was written';
};

subtest 'an unchanged file leaves the row alone' => sub {
    my $before = Registry::DAO::Template->find( $db, { name => 'tenant-signup/pricing' } );
    Registry::DAO::Template->import_from_file( $dao, $file );
    my $after = Registry::DAO::Template->find( $db, { name => 'tenant-signup/pricing' } );

    is $after->updated_at, $before->updated_at,
        'updated_at does not move when the content already matches';

    # But it must still be stamped, or it stays in the bootstrap state for good
    # and a later customisation would be read as "predates stamping" and
    # overwritten. The first production run stamped only 29 of 131 rows
    # because a matching row returned before recording anything.
    $db->update( 'templates',
        { metadata => { -json => {} } }, { id => $after->id } );
    Registry::DAO::Template->import_from_file( $dao, $file );

    my $stamped = Registry::DAO::Template->find( $db, { id => $after->id } );
    is $stamped->metadata->{imported_sha256}, sha_of( $stamped->content ),
        'an unstamped row that already matches its file is stamped in place';
};

# The half the old early-return was protecting, now stated so that it protects
# customisation WITHOUT costing platform templates their deploy path.
#
# Registry is the root tenant, not a different kind of thing, so this is the
# same rule everywhere: an edit made here is an edit by whoever owns the row.
subtest 'a customised row survives import' => sub {
    $db->update( 'templates',
        { content => '<p>the root tenant edited this</p>' },
        { name    => 'tenant-signup/pricing' } );

    Registry::DAO::Template->import_from_file( $dao, $file );

    my $after = Registry::DAO::Template->find( $db, { name => 'tenant-signup/pricing' } );
    is $after->content, '<p>the root tenant edited this</p>',
        'the customisation is not overwritten by the file';
};

subtest 'a tenant schema is governed by the same rule' => sub {
    $db->query('SELECT clone_schema(?)', 'import_test_tenant');
    $db->query('SET search_path = registry, public');

    my $tenant_dao = $dao->schema('import_test_tenant');
    my $tenant_db  = $tenant_dao->db;

    # Seeded by import, so stamped: the file may carry it forward.
    my $seeded = Registry::DAO::Template->import_from_file( $tenant_dao, $file );
    is $seeded->content, $on_disk, 'an absent tenant row is created from the file';

    # Then customised, so it is the tenant's and import must not touch it.
    $tenant_db->update( 'templates',
        { content => '<p>the tenant wrote this</p>' },
        { id      => $seeded->id } );

    Registry::DAO::Template->import_from_file( $tenant_dao, $file );

    my $after = Registry::DAO::Template->find( $tenant_db, { id => $seeded->id } );
    is $after->content, '<p>the tenant wrote this</p>',
        'the tenant customisation survives, by the same rule as the root tenant';
};

done_testing;
