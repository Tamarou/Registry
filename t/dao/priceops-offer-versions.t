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
use Registry::DAO::Resource;
use Registry::DAO::Offer;
use Registry::DAO::OfferVersion;

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

    my $v1 = $offer->draft( $db, { resource_id => $clay->id } );
    is $v1->version, 1, 'the first draft is version 1';
    ok !$v1->is_published, 'and is a draft';
    ok !$offer->current_version($db), 'an offer with only a draft has no current version';

    $v1 = $v1->update( $db, { resource_id => $seat->id } );
    is $v1->resource_id, $seat->id, 'a draft can be edited';

    $v1 = $v1->publish($db);
    ok $v1->is_published, 'publishing marks the version published';
    is $offer->current_version($db)->id, $v1->id, 'and makes it current';

    my $v2 = $offer->draft( $db, { resource_id => $seat->id } );
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

done_testing;
