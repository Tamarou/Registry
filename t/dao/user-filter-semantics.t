#!/usr/bin/env perl
# ABOUTME: User::find and ::list take the filter semantics every other DAO here takes.
# ABOUTME: They hand-build WHERE, so an arrayref or an undef used to bind into `= ?` and match nothing, silently.

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use experimental qw(defer signatures);
use Test::More import => [qw( done_testing is ok like is_deeply subtest )];
defer { done_testing };

use Test::Registry::DB;
use Registry::DAO::User;

my $t_db = Test::Registry::DB->new;
my $dao  = $t_db->db;
my $db   = $dao->db;

my %made;
for my $spec ( [ admin => 'ada' ], [ staff => 'sam' ], [ staff => 'sid' ],
               [ parent => 'pat' ] )
{
    my ( $type, $name ) = @$spec;
    $made{$name} = $dao->create( User => {
        username => $name, user_type => $type,
        email => "$name\@filter.example", name => ucfirst $name,
    } );
}

# Only the users this file made. The test database ships with a seeded
# platform_admin, and asserting against an empty database would make this file
# fail for a reason that has nothing to do with filter semantics.
my %mine = map { $_ => 1 } keys %made;
sub usernames ( $list ) {
    return [ sort grep { $mine{$_} } map { $_->username } @$list ];
}

subtest 'a scalar filter still works' => sub {
    is_deeply usernames( Registry::DAO::User->list( $db, { user_type => 'staff' } ) ),
        [qw( sam sid )], 'two staff';
    is_deeply usernames( Registry::DAO::User->list( $db, { user_type => 'admin' } ) ),
        ['ada'], 'one admin';
};

# The defect. Every other find/list in Registry goes through SQL::Abstract, where
# an arrayref means IN -- so this method's signature looked identical to the
# others and behaved differently, by returning nothing rather than complaining.
subtest 'an arrayref means IN, as it does everywhere else' => sub {
    is_deeply usernames(
        Registry::DAO::User->list( $db, { user_type => [ 'admin', 'staff' ] } ) ),
        [qw( ada sam sid )], 'admins and staff together';

    # The call Controller::People wanted to make, and could not: it does one
    # query per role with a comment explaining why.
    my $one = Registry::DAO::User->list( $db, { user_type => [ 'admin', 'staff' ] } );
    is scalar( @{ usernames($one) } ), 3, 'in a single query';

    # find shares the construction, so it shares the fix.
    my $found = Registry::DAO::User->find( $db, { user_type => [ 'admin', 'staff' ] } );
    ok $found, 'find honours it too';
    ok scalar( grep { $found->username eq $_ } qw( ada sam sid ) ),
        'and returns one of them rather than nothing';
};

subtest 'a one-element list is still a list' => sub {
    is_deeply usernames( Registry::DAO::User->list( $db, { user_type => ['staff'] } ) ),
        [qw( sam sid )], 'not accidentally stringified';
};

# The second silent-nothing in the same loop, found while fixing the first.
# `{ deactivated_at => undef }` bound `= NULL`, which is never true -- so asking
# for active users returned none of them.
subtest 'undef means IS NULL, not = NULL' => sub {
    $made{sid}->deactivate($db);

    my $active = Registry::DAO::User->list( $db,
        { user_type => 'staff', deactivated_at => undef } );
    is_deeply usernames($active), ['sam'],
        'the active staff member, not an empty list';

    # = NULL is never true, so the old construction answered "nobody is active".
    ok scalar(@$active), 'asking for active users returns some';
};

subtest 'an empty list matches nothing, deliberately' => sub {
    my $none = Registry::DAO::User->list( $db, { user_type => [] } );
    is_deeply $none, [], 'no rows at all, not merely none of ours';

    # SQL::Abstract's answer for IN (), and the honest one: an empty set of
    # acceptable values accepts nothing. Pinned so it stays a decision -- the
    # alternative, IN (), is a syntax error rather than a result.
};

subtest 'the filter is not mutated under the caller' => sub {
    # list() deletes 'password' from the hash it is handed, so a caller reusing
    # a filter across two calls gets a different one back. The arrayref must not
    # be flattened in place for the same reason.
    my $filter = { user_type => [ 'admin', 'staff' ] };
    Registry::DAO::User->list( $db, $filter );
    is_deeply $filter, { user_type => [ 'admin', 'staff' ] },
        'the caller keeps the filter they passed';
};

$t_db->cleanup_test_database;
