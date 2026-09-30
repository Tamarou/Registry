#!/usr/bin/env perl
# ABOUTME: Alex sets how long a tenant may sit unused before it is called inert, as a row he can see.
# ABOUTME: NULL is not set and 0 is never; "never" must be distinguishable from "found nothing".

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use experimental qw(defer signatures);
use Test::More import => [qw( done_testing is ok like is_deeply subtest note )];
defer { done_testing };

use Test::Registry::DB;
use Registry::DAO::Tenant;
use Registry::DAO::PlatformSetting;
use Registry::DAO::User;


my $t_db = Test::Registry::DB->new;
my $dao  = $t_db->db;
my $db   = $dao->db;

# Set the window the way Alex would, through the setting rather than the
# environment: the value he can see is the value that applies.
sub window ( $value ) {
    Registry::DAO::PlatformSetting->set( $db, 'inert_tenant_days', $value );
}

sub tenant_aged ( $slug, $days ) {
    my $admin = $dao->create( User => {
        username => "${slug}_admin", user_type => 'admin',
        email => "$slug\@aged.example", name => ucfirst $slug,
    } );
    Registry::DAO::Tenant->provision( $db, {
        name => ucfirst($slug) . ' Studio', slug => $slug, users => [$admin],
    } );
    $db->query(
        "UPDATE registry.tenants SET created_at = now() - (\$1 || ' days')::interval WHERE slug = \$2",
        $days, $slug );
}

sub reported ( $inert ) { return [ sort map { $_->{slug} } @{ $inert->{tenants} } ] }

# Three states, not two: not set, 0, and N. perigrin: "NULL is not set, 0 is
# Never." Collapsing them either way is a bug with teeth, and both directions are
# asserted below.
subtest 'the setting is visible before anybody sets it' => sub {
    # Seeded, not created on first write. A key/value store Alex has to already
    # know the keys of is not configuration he can see.
    my $all = Registry::DAO::PlatformSetting->all($db);
    my ($setting) = grep { $_->key eq 'inert_tenant_days' } @$all;

    ok $setting, 'inert_tenant_days is listed';
    is $setting->value, undef, 'with no value yet';
    like $setting->description, qr/inert/i, 'and a description of what it does';
    like $setting->default_note, qr/90/,    'and what applies when it is not set';
};

subtest 'not set means the platform has no opinion, so ninety stands' => sub {
    window(undef);
    is Registry::DAO::Tenant->inert_after_days($db), 90,
        'a tenant sits unused for a quarter before anybody calls it abandoned';

    # perigrin's number. A studio that signs up before a school year and opens in
    # September would be reaped by an impatient one, and reaping means dropping a
    # schema.

    # A row somebody blanked is somebody who has not decided, not somebody
    # choosing never -- which is the difference between a report running and a
    # report silently switched off.
    window('');
    is Registry::DAO::Tenant->inert_after_days($db), 90,
        'and a blank value is still not set, not never';

    window('   ');
    is Registry::DAO::Tenant->inert_after_days($db), 90,
        'whitespace likewise';

    window(undef);
};

subtest 'Alex sets the window' => sub {
    window('30');
    is Registry::DAO::Tenant->inert_after_days($db), 30, 'thirty, if he says thirty';

    window('365');
    is Registry::DAO::Tenant->inert_after_days($db), 365, 'or a year';

    window(undef);
};

subtest 'zero is never, and so are the words for it' => sub {
    # 0 is canonical. The words are accepted because "never" is what somebody
    # writing render.yaml reaches for, and a config file that only takes a magic
    # number is one nobody reads twice.
    for my $off (qw( 0 never off none no )) {
        window($off);
        is Registry::DAO::Tenant->inert_after_days($db), undef,
            "'$off' means no tenant is ever considered inert";
    }
    window(undef);
};

subtest 'nonsense falls back to the default rather than to zero' => sub {
    # The dangerous misreading. If "soon" became 0, every tenant would be
    # reported inert the moment it was created -- and a report is the input to a
    # deletion.
    for my $junk (qw( soon -5 9.5 ), 'lots' ) {
        window($junk);
        is Registry::DAO::Tenant->inert_after_days($db), 90,
            "'$junk' is not a number of days, so the default stands";
    }
    window(undef);
};

subtest 'the window decides what is reported' => sub {
    tenant_aged( 'quiet_sixty',  60 );
    tenant_aged( 'quiet_twenty', 20 );

    window('90');
    is_deeply reported( Registry::DAO::Tenant->inert($db) ), [],
        'at ninety days neither is old enough';

    window('30');
    is_deeply reported( Registry::DAO::Tenant->inert($db) ), ['quiet_sixty'],
        'at thirty, the sixty-day-old one is';

    window('10');
    is_deeply reported( Registry::DAO::Tenant->inert($db) ),
        [ 'quiet_sixty', 'quiet_twenty' ], 'at ten, both';

    window(undef);
};

# The part that matters more than the number. A report that returns nothing
# because it is switched off looks exactly like a report that found nothing, and
# an operator acting on the second would be wrong about the first.
subtest 'off is said out loud, not returned as an empty list' => sub {
    tenant_aged( 'quiet_ancient', 4000 );

    window('0');
    my $inert = Registry::DAO::Tenant->inert($db);

    is_deeply reported($inert), [], 'nothing is reported';
    ok !$inert->{enabled}, 'and the result says reclaiming is switched off';
    is $inert->{window_days}, undef, 'with no window to have applied';

    window('30');
    my $on = Registry::DAO::Tenant->inert($db);
    ok $on->{enabled}, 'switched on, it says so';
    is $on->{window_days}, 30, 'and which window it used';
    ok scalar( grep { $_->{slug} eq 'quiet_ancient' } @{ $on->{tenants} } ),
        'and finds the tenant the off switch was hiding';

    window(undef);
};

subtest 'an explicit window overrides the setting, but cannot override off' => sub {
    window('0');

    # A caller asking for a number gets one: the CLI's argument is for looking,
    # and looking is not reclaiming.
    my $looked = Registry::DAO::Tenant->inert( $db, older_than_days => 10 );
    ok $looked->{enabled}, 'asking for a window looks anyway';
    is $looked->{window_days}, 10, 'using the window asked for';
    ok scalar( @{ $looked->{tenants} } ), 'and reports what it finds';

    window(undef);
};

subtest 'a key that does not exist is refused, not quietly created' => sub {
    # A typo would otherwise make a row nothing reads, which looks exactly like
    # a setting that is not working.
    my $err = do { local $@; eval {
        Registry::DAO::PlatformSetting->set( $db, 'inert_tenant_dayz', '30' ); 1 }; $@ };
    like $err, qr/not a platform setting/, 'the typo is named as one';

    is Registry::DAO::PlatformSetting->get( $db, 'inert_tenant_dayz' ), undef,
        'and nothing was stored under it';
};

$t_db->cleanup_test_database;
