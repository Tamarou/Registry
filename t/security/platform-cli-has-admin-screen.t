#!/usr/bin/env perl
# ABOUTME: Every `registry platform` subcommand has an equivalent platform admin screen, or is the deploy-time bootstrap.
# ABOUTME: The settings screen is the platform tenant's own admin surface: its admins read and change what the CLI does.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use experimental 'signatures';
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Helpers qw( authenticate_as );
use Registry::DAO::Tenant;
use Registry::DAO::PlatformSetting;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $platform = Registry::DAO::Tenant->platform($db);
my $alex     = $platform->primary_user($db);
ok $alex, 'the platform tenant came with its owner';

sub signed_in_as ($user) {
    my $t = Test::Registry::Mojo->new('Registry');
    $t->app->helper( dao => sub { $dao } );
    authenticate_as( $t, $user ) if $user;
    return $t;
}

# The text of one setting's row on the screen, by the part asked for.
sub row_text ( $t, $key, $part ) {
    my $el = $t->tx->res->dom->at(qq{[data-setting="$key"] .setting-$part});
    return $el ? $el->all_text =~ s/^\s+|\s+$//gr : undef;
}

subtest 'a platform admin sees every platform setting on the settings screen' => sub {
    Registry::DAO::PlatformSetting->set( $db, 'inert_tenant_days', undef );
    Registry::DAO::PlatformSetting->set( $db, 'unverified_tenant_daily_mail_cap', '150' );

    my $settings = Registry::DAO::PlatformSetting->all($db);
    ok scalar @$settings, 'there are platform settings to show';

    my $t = signed_in_as($alex);
    $t->get_ok('/platform/settings')->status_is(200)
      ->content_like( qr/id="platform-nav"/, 'the screen carries the platform nav' );

    for my $s (@$settings) {
        is row_text( $t, $s->key, 'key' ), $s->key, $s->key . ' is on the page';
        is row_text( $t, $s->key, 'description' ), $s->description,
            '  with its description';
        is row_text( $t, $s->key, 'default' ), $s->default_note,
            '  and its default note';
    }

    is row_text( $t, 'inert_tenant_days', 'value' ), '(not set)',
        'a key with no value reads (not set), as the CLI prints it';
    is row_text( $t, 'unverified_tenant_daily_mail_cap', 'value' ), '150',
        'a key with a value shows it';
};

done_testing;
