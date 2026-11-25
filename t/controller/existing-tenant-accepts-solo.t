#!/usr/bin/env perl
# ABOUTME: An existing tenant, created the way sql/seed/sacp-tenant.sql creates SACP, accepts Solo once through platform-offer-acceptance.
# ABOUTME: Admin only; the holder is always the tenant whose host it is; only a current registry offer to tenants is accepted, once.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use List::Util qw( uniq );
use Mojo::File qw( path );
use Mojo::Home;
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Offers qw( offer_terms );
use Test::Registry::Helpers qw( authenticate_as import_all_workflows join_tenant platform_solo_offer_version_id );
use Registry;
use Registry::DAO;
use Registry::DAO::Entitlement;
use Registry::DAO::Offer;
use Registry::PriceOps::PlatformTerms qw( platform_terms_for_tenant );

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
$ENV{DB_URL} = $test_db->uri;
import_all_workflows($dao);

my $SOLO = platform_solo_offer_version_id($dao);

# A tenant as sql/seed/sacp-tenant.sql creates SACP: its registry row and a
# cloned schema, no platform entitlement. Then the seed README's one-time step,
# `./registry workflow import <slug>`, which imports every workflow into it.
# Returns the tenant's id, an admin and a staff member of it, and its Host header.
sub sacp_like ($slug) {
    $db->query( 'INSERT INTO registry.tenants (slug, name) VALUES (?, ?)', $slug, "Studio $slug" );
    $db->query( 'SELECT registry.clone_schema(?)', $slug );
    $db->query('SET search_path = registry, public');
    $dao->connect_schema($slug)
        ->import_workflows( [ Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each ] );
    my %user;
    for my $role (qw(admin staff)) {
        $user{$role} = Test::Registry::Fixtures::create_user( $dao, {
            username => "${slug}_$role", name => "\u$role of $slug", email => "$role\@$slug.test", user_type => $role,
        } );
        join_tenant( $dao, $user{$role}, $role, $slug );
    }
    my $id = $db->query( 'SELECT id FROM registry.tenants WHERE slug = ?', $slug )->array->[0];
    return ( $id, @user{qw(admin staff)}, { Host => "$slug.localhost" } );
}

sub entitlements_of ($tenant_id) {
    $db->query( 'SELECT * FROM registry.entitlements WHERE holder_tenant_id = ?', $tenant_id )->hashes->to_array;
}

sub runs_in ($slug) {
    $db->query( qq{SELECT count(*) FROM "$slug".workflow_runs r JOIN "$slug".workflows w ON w.id = r.workflow_id
                    WHERE w.slug = 'platform-offer-acceptance'} )->array->[0];
}

sub latest_run_in ($slug) {
    $db->query( qq{SELECT r.id FROM "$slug".workflow_runs r JOIN "$slug".workflows w ON w.id = r.workflow_id
                    WHERE w.slug = 'platform-offer-acceptance' ORDER BY r.created_at DESC LIMIT 1} )->array->[0];
}

sub client ( $user = undef ) {
    my $t = Test::Registry::Mojo->new('Registry');
    authenticate_as( $t, $user ) if $user;
    return $t;
}

my $css = join '', map { path( 'public/css', $_ )->slurp } qw( theme.css app.css );

sub check_screen ( $t, $screen ) {
    my @classes = uniq map { split ' ', $_->attr('class') }
        $t->tx->res->dom->find('#workflow-content [class]')->each;
    is_deeply [ grep { $css !~ /\.\Q$_\E(?![\w-])/ } @classes ], [], "$screen uses design-system classes only";
}

# $t's own session CSRF token, for a hand-made POST.
sub csrf ( $t, $host ) {
    $t->get_ok( '/' => $host );
    my $meta = $t->tx->res->dom->at('meta[name="csrf-token"]');
    return $meta ? $meta->attr('content') : '';
}

# Posts the page's form as a browser would, with %fields on top (which need
# not be fields the form offers). Returns its action and the redirect.
sub post_form ( $t, $host, $screen, %fields ) {
    my $form = $t->tx->res->dom->at('#workflow-content form');
    ok $form, "$screen has a form" or return;
    my %held = map { $_->attr('name') => $_->attr('value') }
        grep { defined $_->attr('value') && ( ( $_->attr('type') // '' ) !~ /\A(?:radio|checkbox)\z/
            || exists $_->attr->{checked} ) } $form->find('input[name]')->each;
    my $action = $form->attr('action');
    $t->post_ok( $action => $host => form => { %held, %fields } );
    return ( $action, $t->tx->res->headers->location // '' );
}

sub submit_step ( $t, $host, $screen, %fields ) {
    my ( $action, $next ) = post_form( $t, $host, $screen, %fields ) or return;
    $t->status_is( 302, "$screen accepts it" );
    isnt $next, $action, "$screen moves on" or diag $t->tx->res->body;
    $t->get_ok( $next => $host )->status_is(200);
    return $action;
}

sub refused_step ( $t, $host, $screen, %fields ) {
    my ( $action, $next ) = post_form( $t, $host, $screen, %fields ) or return;
    $t->get_ok( $next => $host ) if $next;
    is $t->tx->req->url->path->to_string, $action, "$screen stays";
    $t->element_exists( '#workflow-content .alert-error', "$screen says why" );
    return $action;
}

subtest 'sacp like tenant accepts solo' => sub {
    my ( $id, $admin, undef, $host ) = sacp_like('sacp_like');
    ok !eval { platform_terms_for_tenant( $db, 'sacp_like' ) }, 'it starts with no platform terms';

    my $t = client($admin);
    $t->get_ok( '/platform-offer-acceptance' => $host )->status_is(200);
    check_screen( $t, 'choose' );
    $t->content_like(qr/Solo/)->content_like(qr/2\.5%/);
    submit_step( $t, $host, 'choose', offer_version => $SOLO );
    check_screen( $t, 'accept' );
    $t->content_like(qr/Solo/)->content_like(qr/2\.5%/);
    submit_step( $t, $host, 'accept', action => 'accept' );
    check_screen( $t, 'complete' );
    $t->content_like(qr/Solo/);

    my $held = entitlements_of($id);
    is scalar @$held, 1, 'registry holds one entitlement for the tenant';
    is_deeply [ $held->[0]->@{qw( offer_version_id payment_plan_id state )} ], [ $SOLO, 'revenue_share', 'active' ],
        "stamped with Solo's version and plan, and active";
    my $terms = platform_terms_for_tenant( $db, 'sacp_like' );
    is $terms->{name}, 'Solo', 'its platform terms are Solo';
    is $terms->{fraction}, '0.025', 'and its revenue share resolves to 2.5%';
};

subtest 'platform-offer-acceptance admits admin and refuses staff' => sub {
    my ( $id, $admin, $staff, $host ) = sacp_like('gate_studio');
    client($admin)->get_ok( '/platform-offer-acceptance' => $host )->status_is( 200, 'the admin is admitted' );
    my $runs = runs_in('gate_studio');
    client($staff)->get_ok( '/platform-offer-acceptance' => $host )->status_is( 403, 'staff is refused' );
    is runs_in('gate_studio'), $runs, 'and the refusal creates no run';
};

subtest 'staff refused platform offer acceptance' => sub {
    my ( $id, $admin, $staff, $host ) = sacp_like('staff_studio');
    my $a = client($admin);
    $a->get_ok( '/platform-offer-acceptance' => $host )->status_is(200);
    my $choose = $a->tx->res->dom->at('#workflow-content form')->attr('action');

    my $t = client($staff);
    $t->get_ok( '/platform-offer-acceptance' => $host )->status_is( 403, 'staff cannot start it' );
    $t->post_ok( $choose => $host => form => { offer_version => $SOLO, csrf_token => csrf( $t, $host ) } )
        ->status_is( 403, "nor post to an admin's run" );
    ( my $accept = $choose ) =~ s{/choose\z}{/accept};
    $t->post_ok( $accept => $host => form => { action => 'accept', csrf_token => csrf( $t, $host ) } )
        ->status_is( 403, 'nor to its accept step' );
    is scalar entitlements_of($id)->@*, 0, 'no entitlement is created';
};

subtest 'tenant already holding solo is told so' => sub {
    my ( $id, $admin, undef, $host ) = sacp_like('solo_holder');
    Registry::DAO::Entitlement->accept( $db,
        { holder_tenant_id => $id, offer_version_id => $SOLO, payment_plan_id => 'revenue_share' } );

    my $t = client($admin);
    $t->get_ok( '/platform-offer-acceptance' => $host )->status_is(200);
    $t->content_like( qr/already holds Solo/, 'the choose screen says it already holds Solo' );
    $t->element_exists_not( '#workflow-content form', 'and offers nothing to accept' );

    # Posted anyway, by hand: refused at the accept, saying so.
    my $run = latest_run_in('solo_holder');
    $t->post_ok( "/platform-offer-acceptance/$run/choose" => $host =>
        form => { offer_version => $SOLO, csrf_token => csrf( $t, $host ) } )->status_is(302);
    $t->get_ok( $t->tx->res->headers->location => $host )->status_is(200);
    refused_step( $t, $host, 'accept', action => 'accept' );
    $t->content_like( qr/already holds/, 'the accept says it already holds it' );
    is scalar entitlements_of($id)->@*, 1, 'no second entitlement is created';
};

subtest 'posted holder of another tenant ignored' => sub {
    my ( $id,       $admin ) = sacp_like('holder_a');
    my ( $other_id, undef, undef, undef ) = sacp_like('holder_b');
    my $host = { Host => 'holder_a.localhost' };
    my %forged = (
        holder_tenant_id => $other_id, holder => 'holder_b', tenant => $other_id,
        tenant_id        => $other_id, tenant_slug => 'holder_b', __tenant_slug => 'holder_b',
    );

    my $t = client($admin);
    $t->get_ok( '/platform-offer-acceptance' => $host )->status_is(200);
    submit_step( $t, $host, 'choose', offer_version => $SOLO, %forged );
    submit_step( $t, $host, 'accept', action => 'accept', %forged );

    is scalar entitlements_of($id)->@*,       1, 'the entitlement is created for the tenant whose host it is';
    is scalar entitlements_of($other_id)->@*, 0, 'the posted tenant gains nothing';
};

subtest 'unauthenticated visitor sent to sign in' => sub {
    my ( $id, undef, undef, $host ) = sacp_like('anon_studio');
    my $runs = runs_in('anon_studio');
    my $t    = client();
    $t->get_ok( '/platform-offer-acceptance' => $host )->status_is(302);
    like $t->tx->res->headers->location, qr{/auth/login}, 'the visitor is sent to sign in';
    is runs_in('anon_studio'), $runs, 'no run is created';
    is scalar entitlements_of($id)->@*, 0, 'no entitlement is created';
};

subtest 'unpublished or foreign offer version refused' => sub {
    my ( $id,       $admin ) = sacp_like('offer_chooser');
    my ( $other_id, $other_admin ) = sacp_like('offer_foreign');
    my %PLATFORM_TERMS = ( price_cents => 0,
        payment_plans => [ { id => 'revenue_share', kind => 'percentage_of_sales', fraction => 0.01 } ] );

    # A registry draft of an offer to tenants, never published.
    my $processing = $db->query(q{SELECT id FROM registry.resources WHERE name = 'payment processing'})
        ->array->[0];
    my $draft = Registry::DAO::Offer->create( $db, { name => 'Draft processing' } )
        ->draft( $db, offer_terms( $processing, %PLATFORM_TERMS ) );

    # Another tenant's published offer, in its own schema.
    my $foreign_db = $dao->connect_schema('offer_foreign')->db;
    my $seats = Test::Registry::Fixtures::create_resource( $foreign_db,
        { name => 'Foreign seats', kind => 'finite', capacity => 5 } );
    my $foreign = Registry::DAO::Offer->create( $foreign_db, { name => 'Foreign offer' } )
        ->draft( $foreign_db, offer_terms( $seats->id, %PLATFORM_TERMS ) )->publish($foreign_db);

    my $host = { Host => 'offer_chooser.localhost' };
    my $t    = client($admin);
    $t->get_ok( '/platform-offer-acceptance' => $host )->status_is(200);
    refused_step( $t, $host, 'choose', offer_version => $draft->id );
    refused_step( $t, $host, 'choose', offer_version => $foreign->id );

    # Chosen properly, then the run's stored choice turned into each of them:
    # the accept re-reads it from the listing and refuses.
    submit_step( $t, $host, 'choose', offer_version => $SOLO );
    my $run = latest_run_in('offer_chooser');
    for my $version ( $draft, $foreign ) {
        $db->query( q{UPDATE offer_chooser.workflow_runs
                         SET data = jsonb_set(data, '{platform_offer_version}', to_jsonb(?::text)) WHERE id = ?},
            $version->id, $run );
        refused_step( $t, $host, 'accept', action => 'accept' );
    }

    is scalar entitlements_of($id)->@*, 0, 'nothing is accepted';
    is $db->query( 'SELECT count(*) FROM registry.entitlements WHERE offer_version_id IN (?, ?)',
        $draft->id, $foreign->id )->array->[0], 0, 'by anyone, of either version';
};

subtest 'double submit creates one entitlement' => sub {
    my ( $id, $admin, undef, $host ) = sacp_like('double_studio');
    my $t = client($admin);
    $t->get_ok( '/platform-offer-acceptance' => $host )->status_is(200);
    submit_step( $t, $host, 'choose', offer_version => $SOLO );
    my $accept = submit_step( $t, $host, 'accept', action => 'accept' );

    $t->post_ok( $accept => $host => form => { action => 'accept', csrf_token => csrf( $t, $host ) } );
    isnt $t->tx->res->body, 'CSRF token validation failed', 'the replay passes the CSRF check';
    is scalar entitlements_of($id)->@*, 1, 'the replay creates no second entitlement';
};

done_testing;
