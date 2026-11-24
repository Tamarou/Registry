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

done_testing;
