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
use Test::Registry::Helpers qw(join_tenant);
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

# The platform tenant's primary member, if that member is admin-role, with the
# profile email that magic links go to.
sub platform_primary_admin ($db) {
    return $db->query(q{
        SELECT u.id, u.username, up.email, up.xmin::text AS profile_version
          FROM registry.tenant_users tu
          JOIN registry.tenants t ON t.id = tu.tenant_id
          JOIN registry.users u ON u.id = tu.user_id
          LEFT JOIN registry.user_profiles up ON up.user_id = u.id
         WHERE t.slug = 'registry' AND tu.is_primary AND tu.role = 'admin'
    })->hash;
}

sub platform_admin_members ($db) {
    return $db->query(q{
        SELECT u.id, tu.is_primary, up.email
          FROM registry.tenant_users tu
          JOIN registry.tenants t ON t.id = tu.tenant_id
          JOIN registry.users u ON u.id = tu.user_id
          LEFT JOIN registry.user_profiles up ON up.user_id = u.id
         WHERE t.slug = 'registry' AND tu.role = 'admin'
    })->hashes->to_array;
}

sub user_count ($db) {
    return $db->query('SELECT COUNT(*) FROM registry.users')->array->[0];
}

# Run $code with the platform tenant's memberships removed, then put the
# seed's members back and remove any user the code made a member. Not a
# transaction: User->create begins its own, which cannot nest.
sub without_platform_members ( $db, $code ) {
    my $platform_id = Registry::DAO::Tenant->platform($db)->id;
    my $saved = $db->select( 'registry.tenant_users', '*',
        { tenant_id => $platform_id } )->hashes->to_array;
    my %seed = map { $_->{user_id} => 1 } @$saved;
    my $users_before = $db->select( 'registry.users', 'id' )->arrays->map( sub { $_->[0] } )->to_array;
    my %existed = map { $_ => 1 } @$users_before;

    $db->delete( 'registry.tenant_users', { tenant_id => $platform_id } );
    my $ok  = eval { $code->(); 1 };
    my $err = $@;

    $db->delete( 'registry.tenant_users', { tenant_id => $platform_id } );
    my @made = grep { !$existed{$_} }
        $db->select( 'registry.users', 'id' )->arrays->map( sub { $_->[0] } )->@*;
    for my $id (@made) {
        $db->delete( 'registry.user_profiles', { user_id => $id } );
        $db->delete( 'registry.users',         { id      => $id } );
    }
    $db->insert( 'registry.tenant_users', $_ ) for @$saved;

    die $err unless $ok;
}

my $configured = {
    PLATFORM_STRIPE_ACCOUNT_ID => 'acct_test_platform',
    PLATFORM_STRIPE_READY      => 1,
    PLATFORM_ADMIN_EMAIL       => 'alex@tamarou.test',
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
        PLATFORM_ADMIN_EMAIL       => 'alex@tamarou.test',
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
        Registry::DAO::Tenant->bootstrap_platform( $db,
            { PLATFORM_STRIPE_READY => 1, PLATFORM_ADMIN_EMAIL => 'alex@tamarou.test' } );
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
    join_tenant( $dao, $admin );
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
            PLATFORM_ADMIN_EMAIL       => 'alex@tamarou.test',
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

subtest 'a malformed account id is refused by name' => sub {
    my $db = $dao->db;
    reset_platform($db);
    Registry::DAO::Tenant->bootstrap_platform( $db, {%$configured} );
    my $before = platform_row($db);

    for my $bad ( '', '   ', 'cus_not_an_account', ' acct_test_platform' ) {
        my $ok = eval {
            Registry::DAO::Tenant->bootstrap_platform( $db,
                { %$configured, PLATFORM_STRIPE_ACCOUNT_ID => $bad } );
            1;
        };
        ok !$ok, "'$bad' is refused";
        like $@, qr/PLATFORM_STRIPE_ACCOUNT_ID/, 'by the variable name';
        is_deeply platform_row($db), $before, 'and the row is unchanged';
    }
};

subtest 'an unrecognised readiness value is refused by name' => sub {
    my $db = $dao->db;
    reset_platform($db);
    Registry::DAO::Tenant->bootstrap_platform( $db,
        { %$configured, PLATFORM_STRIPE_READY => 'false' } );
    my $before = platform_row($db);
    ok !$before->{stripe_charges_enabled}, "'false' is read as not ready";

    for my $bad ( '', 'maybe', 'yes please', '2' ) {
        my $ok = eval {
            Registry::DAO::Tenant->bootstrap_platform( $db,
                { %$configured, PLATFORM_STRIPE_READY => $bad } );
            1;
        };
        ok !$ok, "'$bad' is refused";
        like $@, qr/PLATFORM_STRIPE_READY/, 'by the variable name';
        is_deeply platform_row($db), $before, 'and both flags are as they were';
    }
};

subtest 'bootstrap refuses to replace a different recorded stripe account' => sub {
    my $db = $dao->db;
    reset_platform($db);

    # An admin has since recorded another account. The deployment value is
    # what the platform started with, not what it has decided since.
    $db->query(q{
        UPDATE registry.tenants SET stripe_connect_account_id = 'acct_chosen_by_admin',
            stripe_charges_enabled = FALSE, stripe_details_submitted = FALSE
        WHERE slug = 'registry'
    });
    my $before = platform_row($db);

    my ( undef, $refusal ) =
        Registry::DAO::Tenant->bootstrap_platform( $db, {%$configured} );

    like $refusal, qr/acct_chosen_by_admin/, 'the refusal names the recorded account';
    like $refusal, qr/acct_test_platform/,   'and the configured one';
    is_deeply platform_row($db), $before, 'and the row is unchanged';
};

subtest 'with no platform tenant row bootstrap creates no tenant' => sub {
    my $db = $dao->db;
    my $tx = $db->begin;    # rolled back when it goes out of scope

    $db->query(q{UPDATE registry.tenants SET slug = 'registry-moved-aside' WHERE slug = 'registry'});
    my $before = tenant_rows($db);

    my $ok = eval { Registry::DAO::Tenant->bootstrap_platform( $db, {%$configured} ); 1 };
    ok !$ok, 'bootstrap does not succeed';
    like $@, qr/platform tenant/i, 'and says there is no platform tenant';
    is_deeply tenant_rows($db), $before, 'no tenant row was created or changed';
};

subtest 'the bootstrap command exits non-zero when a value is missing' => sub {
    reset_platform( $dao->db );
    my $before = platform_row( $dao->db );

    # The real script, as the entrypoint runs it.
    my $out = do {
        local %ENV = %ENV;
        delete $ENV{PLATFORM_STRIPE_ACCOUNT_ID};
        $ENV{PLATFORM_STRIPE_READY} = 'true';
        $ENV{PLATFORM_ADMIN_EMAIL}  = 'alex@tamarou.test';
        $ENV{DB_URL}                = $test_db->uri;
        qx{"$^X" ./registry platform bootstrap 2>&1};
    };
    my $status = $? >> 8;

    isnt $status, 0, 'registry platform bootstrap exits non-zero';
    like $out, qr/PLATFORM_STRIPE_ACCOUNT_ID/, 'and names the missing variable';
    is_deeply platform_row( $dao->db ), $before, 'and the row is unchanged';
};

# The entrypoint runs `platform check` before sqitch deploy, so a configuration
# bootstrap would refuse stops the boot while the database still matches the
# code already serving. It judges the values alone: no database handle.
subtest 'the platform configuration is checked without a database' => sub {
    my %good = (
        PLATFORM_STRIPE_ACCOUNT_ID => 'acct_123',
        PLATFORM_STRIPE_READY      => 'TRUE',
        PLATFORM_ADMIN_EMAIL       => 'alex@tamarou.test',
    );

    is_deeply [ Registry::DAO::Tenant->check_platform_config( {%good} ) ],
        [ 'acct_123', 1, 'alex@tamarou.test' ],
        'a good configuration comes back as account, readiness and email';

    for my $case (
        [ 'a missing variable',     { %good, PLATFORM_ADMIN_EMAIL => undef },   qr/Not set: PLATFORM_ADMIN_EMAIL/ ],
        [ 'a malformed account id', { %good, PLATFORM_STRIPE_ACCOUNT_ID => 'x' }, qr/PLATFORM_STRIPE_ACCOUNT_ID 'x'/ ],
        [ 'an unknown readiness',   { %good, PLATFORM_STRIPE_READY => 'maybe' }, qr/PLATFORM_STRIPE_READY 'maybe'/ ],
        [ 'a two-address email',    { %good, PLATFORM_ADMIN_EMAIL => "a\@b.test\nBcc: c\@d.test" }, qr/PLATFORM_ADMIN_EMAIL/ ],
      )
    {
        my ( $name, $config, $why ) = @$case;
        ok !eval { Registry::DAO::Tenant->check_platform_config($config); 1 },
            "$name is refused";
        like $@, $why, '  by name';
    }
};

subtest 'the check command exits non-zero naming a missing value and writes nothing' => sub {
    reset_platform( $dao->db );
    my $before = platform_row( $dao->db );

    my $out = do {
        local %ENV = %ENV;
        delete $ENV{PLATFORM_ADMIN_EMAIL};
        $ENV{PLATFORM_STRIPE_ACCOUNT_ID} = 'acct_123';
        $ENV{PLATFORM_STRIPE_READY}      = 'true';
        $ENV{DB_URL}                     = $test_db->uri;
        qx{"$^X" ./registry platform check 2>&1};
    };
    my $status = $? >> 8;

    isnt $status, 0, 'registry platform check exits non-zero';
    like $out, qr/PLATFORM_ADMIN_EMAIL/, 'and names the missing variable';
    is_deeply platform_row( $dao->db ), $before, 'and the row is unchanged';
};

subtest 'the check command passes a complete configuration and writes nothing' => sub {
    reset_platform( $dao->db );
    my $before = platform_row( $dao->db );

    my $out = do {
        local %ENV = %ENV;
        $ENV{PLATFORM_STRIPE_ACCOUNT_ID} = 'acct_123';
        $ENV{PLATFORM_STRIPE_READY}      = 'true';
        $ENV{PLATFORM_ADMIN_EMAIL}       = 'alex@tamarou.test';
        $ENV{DB_URL}                     = $test_db->uri;
        qx{"$^X" ./registry platform check 2>&1};
    };
    my $status = $? >> 8;

    is $status, 0, 'registry platform check exits zero'
        or diag $out;
    is_deeply platform_row( $dao->db ), $before, 'and the row is unchanged';
};

subtest 'bootstrap gives the platform primary admin the configured email' => sub {
    my $db = $dao->db;
    reset_platform($db);

    Registry::DAO::Tenant->bootstrap_platform( $db,
        { %$configured, PLATFORM_ADMIN_EMAIL => 'alex@tamarou.test' } );

    my $admin = platform_primary_admin($db);
    ok $admin, 'the platform tenant has a primary admin';
    is $admin->{email}, 'alex@tamarou.test',
        "the primary admin's profile email is the configured address";
    ok Registry::DAO::Tenant->is_platform_admin( $db, $admin->{id} ),
        'and that user is a platform admin';
};

subtest 'bootstrap run twice with the same admin email changes nothing' => sub {
    my $db = $dao->db;
    my $config = { %$configured, PLATFORM_ADMIN_EMAIL => 'alex@tamarou.test' };

    Registry::DAO::Tenant->bootstrap_platform( $db, {%$config} );
    my $admin_first = platform_primary_admin($db);
    my $users_first = user_count($db);

    Registry::DAO::Tenant->bootstrap_platform( $db, {%$config} );

    is_deeply platform_primary_admin($db), $admin_first,
        'the second run did not write to the admin profile';
    is user_count($db), $users_first, 'and created no user';
};

subtest 'bootstrap creates one admin when the platform tenant has none' => sub {
    my $db = $dao->db;

    without_platform_members( $db, sub {
        my $users_before = user_count($db);

        Registry::DAO::Tenant->bootstrap_platform( $db,
            { %$configured, PLATFORM_ADMIN_EMAIL => 'first.admin@tamarou.test' } );

        is user_count($db), $users_before + 1, 'exactly one user was created';
        my $admins = platform_admin_members($db);
        is scalar @$admins, 1, 'the platform tenant has exactly one admin-role member';
        ok $admins->[0]{is_primary}, 'who is its primary member';
        is $admins->[0]{email}, 'first.admin@tamarou.test', 'with the configured address';
        ok Registry::DAO::Tenant->is_platform_admin( $db, $admins->[0]{id} ),
            'and is a platform admin';
    } );
};

subtest 'the bootstrap command reads the admin email from the environment' => sub {
    my $db = $dao->db;

    my $t = Test::Registry::Mojo->new('Registry');
    $t->app->helper( dao => sub { $dao } );

    {
        local %ENV = (
            %ENV,
            PLATFORM_STRIPE_ACCOUNT_ID => 'acct_test_platform',
            PLATFORM_STRIPE_READY      => 'true',
            PLATFORM_ADMIN_EMAIL       => 'alex.from.env@tamarou.test',
        );
        run_command( $t->app, 'bootstrap' );
    }

    is platform_primary_admin($db)->{email}, 'alex.from.env@tamarou.test',
        'the primary admin email came from PLATFORM_ADMIN_EMAIL';
};

# Everything bootstrap could write: the registry row, every profile, every
# membership and the set of users, each with its row version.
sub bootstrap_state ($db) {
    return {
        platform    => platform_row($db),
        profiles    => $db->query('SELECT *, xmin::text AS v FROM registry.user_profiles ORDER BY user_id')->hashes->to_array,
        memberships => $db->query('SELECT *, xmin::text AS v FROM registry.tenant_users ORDER BY tenant_id, user_id')->hashes->to_array,
        users       => $db->query('SELECT id, xmin::text AS v FROM registry.users ORDER BY id')->hashes->to_array,
    };
}

# A studio provisioned the way signup provisions one, with its own admin.
sub provision_studio ( $db, $slug, $email ) {
    my $admin = $dao->create( User => {
        username => "${slug}_admin", user_type => 'admin',
        email    => $email,          name      => ucfirst $slug,
    } );
    my $tenant = Registry::DAO::Tenant->provision( $db, {
        name => ucfirst($slug) . ' Studio', slug => $slug, users => [$admin],
    } );
    return ( $tenant, $admin );
}

subtest 'a malformed or header-injecting admin email is refused by name' => sub {
    my $db = $dao->db;
    Registry::DAO::Tenant->bootstrap_platform( $db, {%$configured} );
    reset_platform($db);    # so a Stripe write would show too
    my $before = bootstrap_state($db);

    for my $bad ( '', '   ', 'alex.tamarou.test', 'alex@', '@tamarou.test',
        "alex\@tamarou.test\nBcc: everyone\@elsewhere.test",
        "alex\@tamarou.test\r\nBcc: everyone\@elsewhere.test",
        'alex @tamarou.test' )
    {
        ( my $shown = $bad ) =~ s/\r?\n/\\n/g;
        my $ok = eval {
            Registry::DAO::Tenant->bootstrap_platform( $db,
                { %$configured, PLATFORM_ADMIN_EMAIL => $bad } );
            1;
        };
        ok !$ok, "'$shown' is refused";
        like $@, qr/PLATFORM_ADMIN_EMAIL/, 'by the variable name';
        is_deeply bootstrap_state($db), $before,
            'and nothing changed: no profile, user, membership or Stripe field';
    }
};

subtest 'a missing admin email creates no user' => sub {
    my $db = $dao->db;

    without_platform_members( $db, sub {
        reset_platform($db);
        my $before = bootstrap_state($db);

        my %config = %$configured;
        delete $config{PLATFORM_ADMIN_EMAIL};
        my $ok = eval { Registry::DAO::Tenant->bootstrap_platform( $db, \%config ); 1 };

        ok !$ok, 'bootstrap does not succeed';
        like $@, qr/PLATFORM_ADMIN_EMAIL/, 'and names the missing variable';
        is_deeply bootstrap_state($db), $before,
            'no user was created and nothing else was written';
    } );
};

subtest 'an admin email already used by a studio user is refused' => sub {
    my $db = $dao->db;
    Registry::DAO::Tenant->bootstrap_platform( $db, {%$configured} );
    my ( undef, $morgan ) = provision_studio( $db, 'morgans', 'morgan@studio.test' );
    reset_platform($db);
    my $before = bootstrap_state($db);

    # Addresses are compared without regard to case: magic links reach both.
    for my $taken ( 'morgan@studio.test', 'Morgan@Studio.TEST' ) {
        my $ok = eval {
            Registry::DAO::Tenant->bootstrap_platform( $db,
                { %$configured, PLATFORM_ADMIN_EMAIL => $taken } );
            1;
        };
        ok !$ok, "'$taken' is refused";
        like $@, qr/\Q$taken\E.*already in use/i, 'as an address already in use';
        is_deeply bootstrap_state($db), $before, 'and nothing was written';
    }

    without_platform_members( $db, sub {
        my $before_bare = bootstrap_state($db);
        my $ok = eval {
            Registry::DAO::Tenant->bootstrap_platform( $db,
                { %$configured, PLATFORM_ADMIN_EMAIL => 'morgan@studio.test' } );
            1;
        };
        ok !$ok, 'with no platform admin it is refused too';
        is_deeply bootstrap_state($db), $before_bare,
            'and no admin was created, nor the studio user made a member';
        ok !Registry::DAO::Tenant->is_platform_admin( $db, $morgan->id ),
            'the studio user is not a platform admin';
    } );

    # The real script, as the entrypoint runs it. Measured afresh: putting the
    # seed's memberships back above rewrote those rows.
    $before = bootstrap_state($db);
    my $out = do {
        local %ENV = %ENV;
        $ENV{PLATFORM_STRIPE_ACCOUNT_ID} = 'acct_test_platform';
        $ENV{PLATFORM_STRIPE_READY}      = 'true';
        $ENV{PLATFORM_ADMIN_EMAIL}       = 'morgan@studio.test';
        $ENV{DB_URL}                     = $test_db->uri;
        qx{"$^X" ./registry platform bootstrap 2>&1};
    };
    my $status = $? >> 8;
    isnt $status, 0, 'registry platform bootstrap exits non-zero';
    like $out, qr/morgan\@studio\.test.*already in use/i, 'and says the address is in use';
    is_deeply bootstrap_state($db), $before, 'and wrote nothing';
};

subtest 'bootstrap never promotes a platform staff member' => sub {
    my $db = $dao->db;

    without_platform_members( $db, sub {
        my $staff = $dao->create( User => {
            username => 'platform_staffer', user_type => 'staff',
            email    => 'staffer@tamarou.test', name => 'Staffer',
        } );
        Registry::DAO::Tenant->platform($db)->add_user( $db, $staff, 1, 'staff' );
        my $staff_membership = $db->select( 'registry.tenant_users', '*',
            { user_id => $staff->id } )->hash;

        Registry::DAO::Tenant->bootstrap_platform( $db,
            { %$configured, PLATFORM_ADMIN_EMAIL => 'new.admin@tamarou.test' } );

        is_deeply $db->select( 'registry.tenant_users', '*', { user_id => $staff->id } )->hash,
            $staff_membership, "the staff member's membership is unchanged";
        ok !Registry::DAO::Tenant->is_platform_admin( $db, $staff->id ),
            'and the staff member is not a platform admin';
        is $db->select( 'registry.user_profiles', 'email', { user_id => $staff->id } )->array->[0],
            'staffer@tamarou.test', 'nor was their email changed';

        my $admins = platform_admin_members($db);
        is scalar @$admins, 1, 'a single admin was created instead';
        isnt $admins->[0]{id}, $staff->id, 'who is not the staff member';
        is $admins->[0]{email}, 'new.admin@tamarou.test', 'with the configured address';
    } );
};

subtest 'bootstrap touches no studio admin email' => sub {
    my $db = $dao->db;
    my ( $studio, $admin ) = provision_studio( $db, 'quiet', 'quiet.admin@studio.test' );
    my $schema  = $db->dbh->quote_identifier( $studio->slug );
    my $profile = sub {
        return [
            $db->query( 'SELECT *, xmin::text AS v FROM registry.user_profiles WHERE user_id = ?', $admin->id )->hash,
            $db->query( "SELECT *, xmin::text AS v FROM $schema.user_profiles WHERE user_id = ?", $admin->id )->hash,
        ];
    };
    my $before = $profile->();
    is $before->[1]{email}, 'quiet.admin@studio.test', "the studio's own copy has the address";

    Registry::DAO::Tenant->bootstrap_platform( $db,
        { %$configured, PLATFORM_ADMIN_EMAIL => 'alex.again@tamarou.test' } );

    is platform_primary_admin($db)->{email}, 'alex.again@tamarou.test',
        'bootstrap did write the platform admin';
    is_deeply $profile->(), $before,
        "the studio admin's profile is unchanged in registry and in the studio's schema";
};

subtest 'the connect action mints no second stripe account' => sub {
    my $db = $dao->db;
    reset_platform($db);
    Registry::DAO::Tenant->bootstrap_platform( $db, {%$configured} );
    my $before = platform_row($db);

    # With no key no Stripe client can be built, so any path that would call
    # Stripe -- to create an account or anything else -- renders "Payments
    # are not configured" (502) instead of returning.
    local $ENV{STRIPE_SECRET_KEY};
    delete $ENV{STRIPE_SECRET_KEY};

    my $t = Test::Registry::Mojo->new('Registry');
    $t->app->helper( dao => sub { $dao } );
    my $admin = $dao->create( User => { username => 'platform_connect_admin', user_type => 'admin' } );
    join_tenant( $dao, $admin );
    authenticate_as( $t, $admin );

    $t->post_ok('/admin/billing/connect')
      ->status_is( 302, 'the platform is sent back to its billing page without asking Stripe' )
      ->header_like( Location => qr{/admin/billing$} );

    is_deeply platform_row($db), $before,
        'stripe_connect_account_id and the readiness flags are unchanged';
};

done_testing;
