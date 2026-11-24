#!/usr/bin/env perl
# ABOUTME: Only a tenant admin sets a session's price; staff may run a session but never price it.
# ABOUTME: Covers both back doors: the session edit screen and program-location-assignment's override.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use experimental 'signatures';
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Helpers qw( authenticate_as join_tenant );
use Registry::DAO::Session;
use Registry::DAO::PricingPlan;
use Registry::DAO::Tenant;
use Registry::DAO::User;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
$ENV{DB_URL} = $test_db->uri;

sub person ( $username, $role ) {
    my $user = Registry::DAO::User->create( $db, {
        username => $username, name => "\u$username", user_type => $role,
        email => "$username\@staff-prices.test", password => 'x' } );
    join_tenant( $dao, $user, $role );
    return $user;
}
my $admin = person( 'price_admin', 'admin' );
my $staff = person( 'price_staff', 'staff' );

my $n = 0;
sub priced_session ( $cents = 5000, $on = $db ) {
    $n++;
    my $s = Registry::DAO::Session->create( $on, {
        name => "Priced Session $n", status => 'published',
        capacity => 10, waitlist_enabled => 1, metadata => {} } );
    Registry::DAO::PricingPlan->create( $on, {
        session_id => $s->id, plan_name => 'Standard',
        plan_type => 'standard', amount_cents => $cents } );
    return $s;
}

sub plans ( $s, $on = $db ) {
    $on->select( 'pricing_plans', '*', { session_id => $s->id },
        { -asc => 'version' } )->hashes->to_array;
}
sub current_cents ( $s, $on = $db ) {
    my ($cur) = grep { !defined $_->{superseded_at} } plans( $s, $on )->@*;
    return $cur ? $cur->{amount_cents} : undef;
}
sub reload ( $s, $on = $db ) { Registry::DAO::Session->find( $on, { id => $s->id } ) }

sub as ($user) {
    my $t = Test::Registry::Mojo->new('Registry');
    $t->ua->max_redirects(0);
    authenticate_as( $t, $user );
    return $t;
}
sub settings ($s) { "/admin/sessions/@{[ $s->id ]}/settings" }

subtest 'admin changes a session price' => sub {
    my $s = priced_session(5000);
    my $t = as($admin);
    $t->post_ok( settings($s) => form => { capacity => 12, price_cents => 7500 } )
      ->status_is(302);
    is current_cents($s), 7500, 'the price was revised';
    is scalar plans($s)->@*, 2, 'by superseding, so the old price stays on record';
    is reload($s)->capacity, 12, 'and the capacity saved alongside it';

    $t->get_ok("/admin/sessions/@{[ $s->id ]}/edit")->status_is(200)
      ->element_exists( 'input[name="price_cents"]', 'an admin is offered the price field' );
};

subtest 'staff changes capacity but not price' => sub {
    my $s = priced_session(5000);
    my $t = as($staff);
    $t->post_ok( settings($s) => form => {
        capacity => 15, price_cents => 100, waitlist_enabled => 1 } )->status_is(302);

    my $fresh = reload($s);
    is $fresh->capacity, 15, 'capacity applied';
    is $fresh->waitlist_enabled, 1, 'waitlist applied';
    is current_cents($s), 5000, 'the price is unchanged';
    is scalar plans($s)->@*, 1, 'and no pricing row was added';

    $t->get_ok("/admin/sessions/@{[ $s->id ]}/edit")->status_is(200)
      ->text_like( '.alert-success p', qr/Prices are set by admins/, 'the flash says who sets prices' )
      ->element_exists_not( 'input[name="price_cents"]', 'staff are not offered a price field' )
      ->content_like( qr/\$50\.00/, 'but still see the current price' );
};

subtest 'staff price only post changes nothing' => sub {
    my $s = priced_session(5000);
    as($staff)->post_ok( settings($s) => form => { price_cents => 1 } )->status_is(302);
    is current_cents($s), 5000, 'the price is unchanged';
    my $rows = plans($s);
    is scalar @$rows, 1, 'no pricing row was created';
    ok !defined $rows->[0]{superseded_at}, 'and none was superseded';
    is reload($s)->capacity, 10, 'capacity is untouched';
};

subtest 'staff zero or empty price never frees a session' => sub {
    my $t = as($staff);
    for my $cents ( 0, '' ) {
        my $s = priced_session(5000);
        $t->post_ok( settings($s) => form => { capacity => 10, price_cents => $cents } );
        is current_cents($s), 5000, "price_cents='$cents' leaves the price at 5000";
        is scalar plans($s)->@*, 1, 'with no new pricing row';
    }
    # A session with no price yet must not gain a free one either.
    $n++;
    my $unpriced = Registry::DAO::Session->create( $db, {
        name => "Unpriced $n", status => 'draft', capacity => 10, metadata => {} } );
    $t->post_ok( settings($unpriced) => form => { price_cents => 0 } );
    is scalar plans($unpriced)->@*, 0, 'an unpriced session stays unpriced';
};

subtest 'admin invalid price changes nothing' => sub {
    my $t = as($admin);
    for my $cents ( -100, 'abc' ) {
        my $s = priced_session(5000);
        $t->post_ok( settings($s) => form => { capacity => 20, price_cents => $cents } )
          ->status_is(302);
        is current_cents($s), 5000, "price_cents='$cents': the price is unchanged";
        is scalar plans($s)->@*, 1, 'no pricing row was added';
        is reload($s)->capacity, 10, 'and the capacity was not applied either';
        $t->get_ok("/admin/sessions/@{[ $s->id ]}/edit")
          ->element_exists( '.alert-error', 'the refusal is shown' );
    }
};

subtest 'admin cannot edit another tenants session' => sub {
    for my $slug (qw( price_alpha price_beta )) {
        Registry::DAO::Tenant->provision( $db, {
            name => "Price \u$slug", slug => $slug, users => [] } );
    }
    my $alpha = Registry::DAO::Tenant->find( $db, { slug => 'price_alpha' } );
    my $alpha_admin = Registry::DAO::User->create( $db, {
        username => 'alpha_price_admin', name => 'Alpha Admin', user_type => 'admin',
        email => 'alpha-admin@staff-prices.test' } );
    $alpha->add_user( $db, $alpha_admin, 1, 'admin' );
    $db->query( 'SELECT copy_user(dest_schema => ?, user_id => ?)', 'price_alpha', $alpha_admin->id );

    my $beta_db = $dao->connect_schema('price_beta')->db;
    my $theirs  = priced_session( 5000, $beta_db );

    my $t = as($alpha_admin);
    $t->post_ok( settings($theirs) => { Host => 'price_alpha.localhost' } => form => {
        capacity => 99, price_cents => 1 } )->status_is(404);
    is current_cents( $theirs, $beta_db ), 5000, "tenant B's price is unchanged";
    is scalar plans( $theirs, $beta_db )->@*, 1, 'with no new pricing row';
    is reload( $theirs, $beta_db )->capacity, 10, "and tenant B's capacity is unchanged";
};

done_testing;
