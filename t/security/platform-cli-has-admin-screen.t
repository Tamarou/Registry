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

subtest 'a platform admin sets a setting from the screen and the change is recorded as theirs' => sub {
    Registry::DAO::PlatformSetting->set( $db, 'inert_tenant_days', undef );

    my $t = signed_in_as($alex);
    $t->get_ok('/platform/settings')->status_is(200);
    ok $t->tx->res->dom->at('form[action="/platform/settings/inert_tenant_days"]'),
        'the screen has a form for the setting';

    # Test::Registry::Mojo carries the page's CSRF token on the POST.
    $t->post_ok( '/platform/settings/inert_tenant_days', form => { value => '45' } )
      ->status_is(302)->header_is( Location => '/platform/settings' );

    is Registry::DAO::PlatformSetting->get( $db, 'inert_tenant_days' ), '45',
        'the new value is stored';
    is $db->select( 'registry.platform_settings', ['updated_by'],
        { key => 'inert_tenant_days' } )->hash->{updated_by}, $alex->id,
        'and updated_by records who changed it';

    $t->get_ok('/platform/settings');
    is row_text( $t, 'inert_tenant_days', 'value' ), '45', 'and the screen shows it';
};

subtest 'a platform admin unsets a setting from the screen' => sub {
    Registry::DAO::PlatformSetting->set( $db, 'inert_tenant_days', '30' );

    my $t = signed_in_as($alex);
    $t->get_ok('/platform/settings')->status_is(200);
    $t->post_ok( '/platform/settings/inert_tenant_days', form => { unset => 1 } )
      ->status_is(302);

    is Registry::DAO::PlatformSetting->get( $db, 'inert_tenant_days' ), undef,
        'the key is back to NULL';

    $t->get_ok('/platform/settings');
    is row_text( $t, 'inert_tenant_days', 'value' ), '(not set)',
        'and the screen shows (not set)';
};

done_testing;
