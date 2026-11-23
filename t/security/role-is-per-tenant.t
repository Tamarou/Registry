#!/usr/bin/env perl
# ABOUTME: Tenant-level authority comes from the membership role for the tenant being acted on.
# ABOUTME: An admin of one tenant is only what their membership says in another (ADR 005, ruling 4).
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use experimental 'signatures';
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Helpers qw( authenticate_as );
use Registry::DAO::Tenant;
use Registry::DAO::User;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
$ENV{DB_URL} = $test_db->uri;

# Two real tenants with real schemas, so `Host: <slug>.localhost` resolves to
# each and the user is loaded from that tenant's own copy of the users table.
for my $slug (qw( role_alpha role_beta )) {
    Registry::DAO::Tenant->provision( $db, {
        name => "Role \u$slug", slug => $slug, users => [],
    } );
}
my $alpha = Registry::DAO::Tenant->find( $db, { slug => 'role_alpha' } );
my $beta  = Registry::DAO::Tenant->find( $db, { slug => 'role_beta' } );
my $platform = Registry::DAO::Tenant->platform($db);

my %HOST = ( alpha => 'role_alpha.localhost', beta => 'role_beta.localhost' );

# Every account here is an admin by the global user_type, which is exactly
# the column that must not decide anything in a tenant.
sub account ($username) {
    Registry::DAO::User->create( $db, {
        username => $username, name => "\u$username", user_type => 'admin',
        email => "$username\@role-per-tenant.test",
    } );
}

sub resident ( $user, @tenants ) {
    $db->query( 'SELECT copy_user(dest_schema => ?, user_id => ?)', $_->slug, $user->id )
        for @tenants;
}

sub app_as ($user) {
    my $t = Test::Registry::Mojo->new('Registry');
    $t->ua->max_redirects(0);
    authenticate_as( $t, $user );
    return $t;
}

subtest 'an admin of one tenant is staff in another' => sub {
    my $morgan = account('role_morgan');
    $alpha->add_user( $db, $morgan, 1, 'admin' );
    $beta->add_user( $db, $morgan, 0, 'staff' );
    resident( $morgan, $alpha, $beta );

    my $t = app_as($morgan);

    $t->get_ok( '/admin/domains' => { Host => $HOST{alpha} } )
      ->status_is( 200, 'Morgan administers the tenant she is an admin of' );

    $t->get_ok( '/admin/domains' => { Host => $HOST{beta} } )
      ->status_is( 403, 'and is refused the admin-only action where she is staff' );

    $t->get_ok( '/admin/people' => { Host => $HOST{beta} } )
      ->status_is( 200, 'while what staff may do there is still served' );
};

subtest 'an admin of one tenant cannot grant administrator in another' => sub {
    # The people screen and user-creation are open to staff, so their "only an
    # admin may grant admin" gates are tenant-level authority too.
    my $morgan = Registry::DAO::User->find( $db, { username => 'role_morgan' } );
    my $beta_db = $dao->connect_schema('role_beta')->db;
    my $target  = Registry::DAO::User->create( $beta_db, {
        username => 'role_beta_teacher', name => 'Beta Teacher', user_type => 'staff',
        email => 'beta-teacher@role-per-tenant.test',
    } );

    my $err = do { local $@; eval { $target->change_role( $beta_db, 'admin', $morgan ) }; $@ };
    like $err, qr/Only an administrator/, 'the DAO refuses the grant in beta';

    my $t = app_as($morgan);
    $t->get_ok( '/admin/people' => { Host => $HOST{beta} } )->status_is(200)
      ->element_exists_not( qq{select#role-@{[ $target->id ]} option[value="admin"]},
        'the people screen does not offer administrator' );
    $t->get_ok( '/admin/people' => { Host => $HOST{alpha} } )->status_is(200);
};

subtest 'a user with no membership of a tenant has no role there' => sub {
    # Resident in beta's schema, but not a member of it.
    my $pat = account('role_pat');
    $alpha->add_user( $db, $pat, 0, 'admin' );
    resident( $pat, $alpha, $beta );

    my $t = app_as($pat);
    $t->get_ok( '/admin/domains' => { Host => $HOST{beta} } )
      ->status_is( 403, 'an admin elsewhere is refused admin-only actions' );
    $t->get_ok( '/admin/people' => { Host => $HOST{beta} } )
      ->status_is( 403, 'and the staff surfaces' );
};

subtest 'a parent member cannot reach staff pages' => sub {
    my $sam = account('role_sam');
    $beta->add_user( $db, $sam, 0, 'parent' );
    resident( $sam, $beta );

    my $t = app_as($sam);
    $t->get_ok( '/admin/people' => { Host => $HOST{beta} } )
      ->status_is( 403, 'the staff people screen is refused' );
    $t->get_ok( '/teacher/' => { Host => $HOST{beta} } )
      ->status_is( 403, 'as is the teacher dashboard' );
};

subtest 'an account local to one tenant has the role that tenant recorded' => sub {
    # Created in beta's schema alone, as storefront registration and the
    # tenant's own user-creation do: there is no registry.users row for a
    # membership to reference, so beta's record of them is their role there.
    my $local = Registry::DAO::User->create( $dao->connect_schema('role_beta')->db, {
        username => 'role_local_staff', name => 'Local Staff', user_type => 'staff',
        email => 'local-staff@role-per-tenant.test',
    } );
    ok !$db->select( 'registry.users', 'id', { id => $local->id } )->hash,
        'the account exists only in the tenant schema';

    my $t = app_as($local);
    $t->get_ok( '/admin/people' => { Host => $HOST{beta} } )
      ->status_is( 200, 'staff surfaces are served' );
    $t->get_ok( '/admin/domains' => { Host => $HOST{beta} } )
      ->status_is( 403, 'admin-only actions are not' );
};

subtest 'everyone a tenant is provisioned with is a member in the role chosen for them' => sub {
    # Tenant signup names an admin and a team; the team are created as
    # registry accounts and copied in, so without a membership they would
    # have no role in the tenant they were just added to.
    my $owner = account('role_gamma_owner');
    my $staff = Registry::DAO::User->create( $db, {
        username => 'role_gamma_staff', name => 'Gamma Staff', user_type => 'staff',
        email => 'gamma-staff@role-per-tenant.test',
    } );
    Registry::DAO::Tenant->provision( $db, {
        name => 'Role Gamma', slug => 'role_gamma', users => [ $owner, $staff ],
    } );

    is Registry::DAO::Tenant->role_in( $db, 'role_gamma', $owner->id ), 'admin',
        'the owner is an admin member';
    is Registry::DAO::Tenant->role_in( $db, 'role_gamma', $staff->id ), 'staff',
        'the team member is a staff member';

    my $t = app_as($staff);
    $t->get_ok( '/admin/people' => { Host => 'role_gamma.localhost' } )
      ->status_is( 200, 'and is served the staff surfaces of their tenant' );
};

subtest 'the platform tenant is a tenant like any other' => sub {
    # The hole ruling 4 closes: every studio owner is an admin by user_type,
    # and the platform host is a tenant whose admin screens they reached.
    my $owner = account('role_owner');
    $alpha->add_user( $db, $owner, 0, 'admin' );

    my $t = app_as($owner);
    $t->get_ok('/admin/domains')
      ->status_is( 403, "a studio's admin has no admin role on the platform" );

    my $support = account('role_support');
    $platform->add_user( $db, $support, 0, 'staff' );
    $t = app_as($support);
    $t->get_ok('/admin/domains')
      ->status_is( 403, 'a staff member of the platform is refused admin-only actions' );
    $t->get_ok('/admin/people')
      ->status_is( 200, 'and served the staff surfaces' );
};

done_testing;
