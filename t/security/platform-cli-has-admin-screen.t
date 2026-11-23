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
use Test::Registry::Fixtures;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::PlatformSetting;
use Registry::Command::platform;
use Test::Registry::PlatformCliAudit;

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

# The audit, decided in the issue that added the screen: each subcommand gets
# an equivalent admin route, or is the deploy-time bootstrap -- the one thing
# that runs before any admin exists, from deployment configuration alone.
my %screen_for = (
    settings => 'platform_settings',
    set      => 'platform_settings_update',
    unset    => 'platform_settings_update',
);
my @deploy_only = ('bootstrap');

subtest 'every registry platform subcommand has an admin screen or is the deploy-time bootstrap' => sub {
    my $usage = Registry::Command::platform->new->usage;
    my @subcommands = $usage =~ /^\s*\*\s+(\S+)/mg;
    ok scalar @subcommands, 'the usage text lists subcommands to audit';

    is_deeply [ Test::Registry::PlatformCliAudit::unmapped( $usage, \%screen_for, \@deploy_only ) ],
        [], 'no subcommand is left without a screen';

    # A map naming a route that does not exist would pass the audit and point
    # at nothing.
    my $t = signed_in_as(undef);
    for my $route ( sort values %screen_for ) {
        ok $t->app->routes->lookup($route), "the $route route exists";
    }
};

subtest 'a subcommand with no admin screen fails the audit' => sub {
    my $usage = <<~'END';
        usage: registry platform <command> [<args>]

          commands:
            * settings           - list every platform setting and its value
            * set <key> <value>  - set one
            * unset <key>        - return one to its default
            * purge <key>        - delete one outright
            * bootstrap          - write deployment configuration
        END

    is_deeply [ Test::Registry::PlatformCliAudit::unmapped( $usage, \%screen_for, \@deploy_only ) ],
        ['purge'], 'the subcommand with no screen is reported by name';

    is_deeply [ Test::Registry::PlatformCliAudit::unmapped( $usage, \%screen_for, [] ) ],
        [ 'purge', 'bootstrap' ],
        'and bootstrap is reported too once it is not deploy-only';
};

# A user the guard should refuse: GET and POST are both answered without the
# page or the write, and the stored value is what it was before.
sub refused_both_ways ( $t, $status, $who ) {
    Registry::DAO::PlatformSetting->set( $db, 'inert_tenant_days', '60' );

    $t->get_ok('/platform/settings')->status_is( $status, "$who is refused the screen" )
      ->content_unlike( qr/inert_tenant_days/, 'and is not shown the settings' );

    # Test::Registry::Mojo supplies a valid CSRF token, so a refusal here is
    # the guard's, not the CSRF check's.
    $t->post_ok( '/platform/settings/inert_tenant_days', form => { value => '7' } )
      ->status_is( $status, "$who is refused the change" )
      ->content_unlike( qr/CSRF/, 'by the guard rather than the CSRF check' );

    is Registry::DAO::PlatformSetting->get( $db, 'inert_tenant_days' ), '60',
        'the stored value is unchanged';
}

subtest 'a staff member of the platform tenant cannot read or change platform settings' => sub {
    # An admin by user_type, so the membership's role is what refuses them.
    my $staff = Registry::DAO::User->create( $db, {
        username => 'platform_settings_staff', name => 'Platform Staff',
        user_type => 'admin', email => 'settings-staff@registry.test',
    } );
    $platform->add_user( $db, $staff, 0, 'staff' );

    refused_both_ways( signed_in_as($staff), 403, 'a platform staff member' );
};

subtest 'an admin of another tenant cannot read or change platform settings' => sub {
    my $morgan = Registry::DAO::User->create( $db, {
        username => 'morgan', name => 'Morgan', user_type => 'admin',
        email => 'morgan@studio.test',
    } );
    my $studio = Test::Registry::Fixtures::create_tenant( $db, {
        name => 'Morgan Studio', slug => 'morgan_studio',
    } );
    $studio->add_user( $db, $morgan, 1 );

    refused_both_ways( signed_in_as($morgan), 403, 'a tenant admin' );
};

subtest 'an unauthenticated request cannot read or change platform settings' => sub {
    # require_auth sends a browser to sign in; not served, either way.
    refused_both_ways( signed_in_as(undef), 302, 'an anonymous visitor' );
};

subtest 'an unknown setting key is refused by name and creates no row' => sub {
    my $rows_before = $db->select( 'registry.platform_settings', 'COUNT(*)' )->array->[0];

    my $t = signed_in_as($alex);
    $t->get_ok('/platform/settings')->status_is(200);
    $t->post_ok( '/platform/settings/no_such_key', form => { value => '5' } )
      ->status_is(400)
      ->text_is( '#settings-error' => q{'no_such_key' is not a platform setting},
          'the refusal names the key, as the CLI does' )
      ->content_like( qr/id="platform-nav"/, 'on the settings screen' );

    is $db->select( 'registry.platform_settings', 'COUNT(*)' )->array->[0], $rows_before,
        'registry.platform_settings gains no row';
    is $db->select( 'registry.platform_settings', 'COUNT(*)',
        { key => 'no_such_key' } )->array->[0], 0, 'and none for that key';
};

subtest 'a blank value is refused rather than stored' => sub {
    # The CLI refuses `set <key>` with no value. Stored, '' would read as "set
    # to nothing", which for these keys is neither the default nor 0.
    Registry::DAO::PlatformSetting->set( $db, 'inert_tenant_days', '60' );

    my $t = signed_in_as($alex);
    $t->get_ok('/platform/settings')->status_is(200);
    $t->post_ok( '/platform/settings/inert_tenant_days', form => { value => '  ' } )
      ->status_is(400)->content_like( qr/needs a value/, 'with the reason' );

    is Registry::DAO::PlatformSetting->get( $db, 'inert_tenant_days' ), '60',
        'the stored value is unchanged';
};

subtest 'a settings change without the csrf token is refused' => sub {
    Registry::DAO::PlatformSetting->set( $db, 'inert_tenant_days', '60' );

    my $t = signed_in_as($alex);
    $t->get_ok('/platform/settings')->status_is(200);

    # An empty token is supplied so Test::Registry::Mojo does not add the real
    # one.
    $t->post_ok( '/platform/settings/inert_tenant_days',
        form => { value => '7', csrf_token => '' } )
      ->status_is(403)->content_like( qr/CSRF/, 'by the CSRF check' );

    is Registry::DAO::PlatformSetting->get( $db, 'inert_tenant_days' ), '60',
        'the stored value is unchanged';
};

done_testing;
