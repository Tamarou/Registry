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
use Registry::DAO::Workflow;
use Registry::DAO::Location;
use Registry::DAO::Project;
use Registry::Utility::WorkflowProcessor;    # defines Registry::WorkflowProcessor
use Mojo::File qw(path);
use DateTime;

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

# program-location-assignment, driven through the real processor and steps.
# The run's `user` is what the controller seeds from the session -- the
# acting user with their role in this tenant -- so a run here starts with it.
my $pla = Registry::DAO::Workflow->from_yaml( $dao,
    path('workflows/program-location-assignment.yml')->slurp );

sub assign_with_override ( $user, $role, $forged = {} ) {
    $n++;
    my $loc = Registry::DAO::Location->create( $db, {
        name => "PLA Loc $n", slug => "pla_loc_$n", address_info => {}, metadata => {} } );
    my $proj = Registry::DAO::Project->create( $db, {
        name => "PLA Proj $n", status => 'published', metadata => {} } );

    my $run = Registry::WorkflowProcessor->new( dao => $dao )->new_run( $pla, {
        user_id    => $user->id,
        user       => { id => $user->id, user_type => $user->user_type, role => $role },
        project_id => $proj->id,
    } );
    my $step = sub ($slug) { $pla->get_step( $db, { slug => $slug } ) };
    $run->process( $db, $step->('choose-locations'), { location_ids => $loc->id } );
    $run->process( $db, $step->('configure-location'), {
        "location_configs[@{[ $loc->id ]}][capacity]"         => 12,
        "location_configs[@{[ $loc->id ]}][schedule][monday]" => '15:00',
        "location_configs[@{[ $loc->id ]}][pricing_override]" => '25.00',
    } );
    $run->process( $db, $step->('generate-events'), {
        confirm_generation                => 1,
        # A week of its own: Schedule::check_conflicts dies on a teacher who
        # already has an event in the window, which is not what is tested here.
        'generation_params[start_date]'     => DateTime->new( year => 2027, month => 1, day => 4 )->add( weeks => $n )->ymd,
        'generation_params[duration_weeks]' => 1,
        %$forged,
    } );

    my $created = Registry::DAO::WorkflowRun->find( $db, { id => $run->id } )
        ->data->{created_sessions} // [];
    return $created->[0] ? $created->[0]{session_id} : undef;
}
sub plan_rows ($session_id) {
    $db->select( 'pricing_plans', '*', { session_id => $session_id } )->hashes->to_array;
}

subtest 'staff location override creates no price' => sub {
    my $as_staff = assign_with_override( $staff, 'staff' );
    ok $as_staff, 'the staff run generated its session';
    is scalar plan_rows($as_staff)->@*, 0, 'but created no pricing row from the override';

    my $as_admin = assign_with_override( $admin, 'admin' );
    ok $as_admin, 'the admin run generated its session';
    my $rows = plan_rows($as_admin);
    is scalar @$rows, 1, 'and the override priced it';
    is $rows->[0]{amount_cents}, 2500, 'at the override, in cents';
};

subtest 'forged admin user creates no override price' => sub {
    my $sid = assign_with_override( $staff, 'staff', {
        'user[role]'      => 'admin',
        'user[user_type]' => 'admin',
    } );
    ok $sid, 'the session was generated';
    is scalar plan_rows($sid)->@*, 0,
        'a user claiming admin in the submitted form prices nothing';
};

done_testing;
