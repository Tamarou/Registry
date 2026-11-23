#!/usr/bin/env perl
# ABOUTME: Deployment configuration writes Tamarou's Stripe account and readiness onto the registry row.
# ABOUTME: Without it the platform reads as not connected and the connect action would mint a second account.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;

use Test::Registry::DB;
use Test::Registry::Mojo;
use Test::Registry::Helpers qw(authenticate_as);
use Registry::DAO::Tenant;
use Registry::Command::platform;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

# A second tenant, so "only the registry row changes" has something to be
# wrong about.
Registry::DAO::Tenant->create( $dao->db, { name => 'Bystander Studio', slug => 'bystander' } );

sub tenant_rows ($db) {
    return $db->query('SELECT * FROM registry.tenants ORDER BY id')->hashes->to_array;
}

sub other_tenant_rows ($db) {
    return [ grep { $_->{slug} ne 'registry' } tenant_rows($db)->@* ];
}

# xmin is the id of the transaction that last wrote the row, so it moves on
# any UPDATE -- even one that writes back the values already there.
sub platform_row ($db) {
    return $db->query(q{SELECT *, xmin::text AS row_version FROM registry.tenants WHERE slug = 'registry'})->hash;
}

# The command's output, captured so it does not land in the TAP stream.
sub run_command ( $app, @args ) {
    open my $fh, '>', \my $out or die "capture: $!";
    my $old = select $fh;
    my $ok  = eval { Registry::Command::platform->new( app => $app )->run(@args); 1 };
    my $err = $@;
    select $old;
    close $fh;
    die $err unless $ok;
    return $out // '';
}

my $configured = {
    PLATFORM_STRIPE_ACCOUNT_ID => 'acct_test_platform',
    PLATFORM_STRIPE_READY      => 1,
};

sub reset_platform ($db) {
    $db->query(q{
        UPDATE registry.tenants SET stripe_connect_account_id = NULL,
            stripe_charges_enabled = FALSE, stripe_details_submitted = FALSE
        WHERE slug = 'registry'
    });
}

subtest 'bootstrap writes the configured stripe account onto the registry row' => sub {
    my $db = $dao->db;
    reset_platform($db);
    my $others_before = other_tenant_rows($db);

    Registry::DAO::Tenant->bootstrap_platform( $db, {
        PLATFORM_STRIPE_ACCOUNT_ID => 'acct_test_platform',
        PLATFORM_STRIPE_READY      => 1,
    } );

    my $row = platform_row($db);
    is $row->{stripe_connect_account_id}, 'acct_test_platform',
        'the registry row names the configured account';
    ok $row->{stripe_charges_enabled},   'charges are enabled';
    ok $row->{stripe_details_submitted}, 'details are submitted';
    ok Registry::DAO::Tenant->platform($db)->stripe_connect_ready,
        'so the platform tenant reads as connect-ready';

    is_deeply other_tenant_rows($db), $others_before, 'no other tenant row changed';
};

subtest 'bootstrap run twice with the same values changes nothing' => sub {
    my $db = $dao->db;
    reset_platform($db);

    Registry::DAO::Tenant->bootstrap_platform( $db, {%$configured} );
    my $after_first = platform_row($db);

    Registry::DAO::Tenant->bootstrap_platform( $db, {%$configured} );
    my $after_second = platform_row($db);

    is_deeply $after_second, $after_first,
        'the second run leaves the row exactly as the first left it';
    is $after_second->{row_version}, $after_first->{row_version},
        'and did not write to it at all';
};

subtest 'a missing account id is reported by name and writes nothing' => sub {
    my $db = $dao->db;
    reset_platform($db);
    my $before = platform_row($db);

    my $ok = eval {
        Registry::DAO::Tenant->bootstrap_platform( $db, { PLATFORM_STRIPE_READY => 1 } );
        1;
    };
    ok !$ok, 'bootstrap does not succeed';
    like $@, qr/PLATFORM_STRIPE_ACCOUNT_ID/, 'and names the missing variable';
    is_deeply platform_row($db), $before, 'the row is as it was';
};

subtest 'the billing page shows the platform tenant as ready' => sub {
    Registry::DAO::Tenant->bootstrap_platform( $dao->db, {%$configured} );

    my $t = Test::Registry::Mojo->new('Registry');
    $t->app->helper( dao => sub { $dao } );
    my $admin = $dao->create( User => { username => 'platform_billing_admin', user_type => 'admin' } );
    authenticate_as( $t, $admin );

    $t->get_ok('/admin/billing')
      ->status_is(200)
      ->content_like(qr/You can take payments/i, 'the platform reads as ready')
      ->content_unlike(qr/Set up payments/i, 'and is not offered a connect it does not need');
};

subtest 'the bootstrap command reads the environment' => sub {
    my $db = $dao->db;
    reset_platform($db);

    my $t = Test::Registry::Mojo->new('Registry');
    $t->app->helper( dao => sub { $dao } );

    {
        local %ENV = (
            %ENV,
            PLATFORM_STRIPE_ACCOUNT_ID => 'acct_from_environment',
            PLATFORM_STRIPE_READY      => 'true',
        );
        my $out = run_command( $t->app, 'bootstrap' );
        like $out, qr/acct_from_environment/, 'the command says what it wrote';
    }

    my $row = platform_row($db);
    is $row->{stripe_connect_account_id}, 'acct_from_environment',
        'the account id came from PLATFORM_STRIPE_ACCOUNT_ID';
    ok $row->{stripe_charges_enabled} && $row->{stripe_details_submitted},
        'and readiness from PLATFORM_STRIPE_READY';
};

done_testing;
