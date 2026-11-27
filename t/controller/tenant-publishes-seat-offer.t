#!/usr/bin/env perl
# ABOUTME: A tenant admin, on the tenant's host, publishes the day-one seat offers through every offer-publishing screen.
# ABOUTME: Checks the stored terms, and that staff, foreign occurrences, over-capacity offers and replays change nothing.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::SoloVersion qw(accept_solo);
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( authenticate_as import_all_workflows join_tenant );
use Registry;
use Registry::DAO;
use Registry::DAO::Tenant;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

# Imported first, then provisioned as a new tenant is, so the tenant's schema
# gets offer-publishing the way a new tenant gets it.
import_all_workflows($dao);
# Each accepts Solo, as signup does, so it holds the run rights its workflows need.
accept_solo( $dao->db, Registry::DAO::Tenant->provision( $dao->db, { name => 'Wheel Studio', slug => 'wheel_studio' } ) );
accept_solo( $dao->db, Registry::DAO::Tenant->provision( $dao->db, { name => 'Other Studio', slug => 'other_studio' } ) );
my $db    = $dao->connect_schema('wheel_studio')->db;
my $other = $dao->connect_schema('other_studio')->db;
my %HOST  = ( Host => 'wheel_studio.localhost' );

my $admin = Test::Registry::Fixtures::create_user( $dao,
    { username => 'wheel_admin', name => 'Wheel Admin', email => 'admin@wheel.test', user_type => 'admin' } );
join_tenant( $dao, $admin, 'admin', 'wheel_studio' );
my $staff = Test::Registry::Fixtures::create_user( $dao,
    { username => 'wheel_staff', name => 'Wheel Staff', email => 'staff@wheel.test', user_type => 'staff' } );
join_tenant( $dao, $staff, 'staff', 'wheel_studio' );

# One occurrence of capacity 10 in $schema_db; returns its id.
sub occurrence_in ($schema_db) {
    state $n = 0;
    $n++;
    my $class = $schema_db->insert( 'projects', { name => "Wheel class $n", slug => "wheel-class-$n" },
        { returning => 'id' } )->hash->{id};
    my $teacher = $schema_db->insert( 'users', { username => "wheel-teacher-$n" }, { returning => 'id' } )
        ->hash->{id};
    my $room = $schema_db->insert( 'locations', { time_zone => 'America/New_York', name => "Wheel room $n", slug => "wheel-room-$n" },
        { returning => 'id' } )->hash->{id};
    return $schema_db->insert( 'events', {
        project_id => $class, location_id => $room, teacher_id => $teacher,
        time       => '2099-03-14T18:00:00Z', duration => 120, capacity => 10,
    }, { returning => 'id' } )->hash->{id};
}
my $occurrence = occurrence_in($db);
my $foreign    = occurrence_in($other);

sub client ($user) {
    my $t = Test::Registry::Mojo->new('Registry');
    authenticate_as( $t, $user );
    return $t;
}

# $t's own session CSRF token, so a hand-made POST passes the CSRF check and
# reaches the gate it is testing.
sub csrf ($t) {
    $t->get_ok( '/' => \%HOST );
    my $meta = $t->tx->res->dom->at('meta[name="csrf-token"]');
    ok $meta, 'the page carries a CSRF token' or return '';
    return $meta->attr('content');
}

# Posts the page's form as a browser would: what the form already holds (its
# checked choices and filled-in values), overridden by %fields, each of which
# the form must offer. Returns the form's action and the response's redirect.
sub post_form ( $t, $screen, %fields ) {
    my $form = $t->tx->res->dom->at('#workflow-content form');
    ok $form, "$screen has a form" or return;
    ok $form->at(qq{[name="$_"]}), "$screen asks for $_" for sort keys %fields;
    my %held = map { $_->attr('name') => $_->attr('value') }
        grep { defined $_->attr('value') && ( ( $_->attr('type') // '' ) !~ /\A(?:radio|checkbox)\z/
            || exists $_->attr->{checked} ) } $form->find('input[name]')->each;
    my $action = $form->attr('action');
    $t->post_ok( $action => \%HOST => form => { %held, %fields } );
    return ( $action, $t->tx->res->headers->location // '' );
}

# Submits the step and follows it on to the next screen. Returns its action.
sub submit_step ( $t, $screen, %fields ) {
    my ( $action, $next ) = post_form( $t, $screen, %fields ) or return;
    $t->status_is( 302, "$screen accepts it" );
    isnt $next, $action, "$screen moves on" or diag $t->tx->res->body;
    $t->get_ok( $next => \%HOST )->status_is(200);
    return $action;
}

# Submits the step and expects it to refuse: it stays, saying why.
sub refused_step ( $t, $screen, %fields ) {
    my ( $action, $next ) = post_form( $t, $screen, %fields ) or return;
    $t->get_ok( $next => \%HOST ) if $next;
    is $t->tx->req->url->path->to_string, $action, "$screen stays";
    $t->element_exists( '#workflow-content .alert-error', "$screen says why" );
    return $action;
}

# Walks offer-publishing from its start up to the publish screen, answering
# each step from %$answers. Returns the action URL of every step it submitted.
sub walk_to_publish ( $t, $answers ) {
    $t->get_ok( '/offer-publishing' => \%HOST )->status_is(200);
    return map { submit_step( $t, $_, $answers->{$_}->%* ) } qw(
        resource offer-basics offer-price one-time-payment percentage-of-sales-payment
        refund-policy change-policy use-policy expiry-policy );
}

my %CHANGE_48 = ( change => 'window', window_hours => 48, fee_cents => 0, targets => 'same_offer' );
my %DAY_ONE = (
    'one-time-payment'            => { one_time            => 'offered' },
    'percentage-of-sales-payment' => { percentage_of_sales => 'declined' },
    'change-policy'               => \%CHANGE_48,
    'use-policy'                  => { use    => 'optional_attendance' },
    'expiry-policy'               => { expiry => 'end_of_occurrence' },
);

# The current published version of the offer named $name, with its plans.
sub current_version ($name) {
    my $v = $db->query( q{
        SELECT v.* FROM offer_versions v JOIN offers o ON o.id = v.offer_id
         WHERE o.name = ? AND v.published_at IS NOT NULL AND v.superseded_at IS NULL
    }, $name )->expand->hash or return;
    $v->{plans} = $db->query( q{
        SELECT kind FROM offer_version_payment_plans WHERE offer_version_id = ? ORDER BY kind
    }, $v->{id} )->arrays->map( sub { $_->[0] } )->to_array;
    return $v;
}

sub versions_of ($name) {
    $db->query( q{
        SELECT v.* FROM offer_versions v JOIN offers o ON o.id = v.offer_id WHERE o.name = ? ORDER BY v.version
    }, $name )->expand->hashes->to_array;
}

sub version_count () { $db->query('SELECT count(*) FROM offer_versions')->array->[0] }

my $resource_id;

subtest 'admin publishes the couples seat offer over http' => sub {
    my $t = client($admin);
    walk_to_publish( $t, {
        %DAY_ONE,
        resource => {
            resource_mode => 'create', resource_name => 'Wheel seats', resource_kind => 'finite',
            capacity      => 10,       event_id      => $occurrence,
        },
        'offer-basics' => { offer_name => "Couple's wheel class" },
        'offer-price'  => { price_cents => 9000, currency => 'USD', units_per_acceptance => 2, per_booking_cap => 2 },
        'refund-policy' => { refund => 'none' },
    } ) or return;
    # The created resource is chosen for the offer on the offer-basics screen.
    ($resource_id) = $db->query( q{SELECT id FROM resources WHERE name = 'Wheel seats'} )->array->@*;
    ok $resource_id, 'the resource was created in the tenant schema';
    submit_step( $t, 'publish', action => 'publish' );
    $t->content_like( qr/Couple(?:&#39;|')s wheel class/, 'the complete page names the offer' );

    is_deeply $db->query( 'SELECT kind, capacity, event_id FROM resources WHERE id = ?', $resource_id )->hash,
        { kind => 'finite', capacity => 10, event_id => $occurrence }, 'a finite 10-seat resource bound to the occurrence';

    my $v = current_version("Couple's wheel class");
    ok $v, 'the couples offer has a current published version' or return;
    is_deeply { $v->%{qw( resource_id class_project_id price_cents currency units_per_acceptance per_booking_cap )} },
        { resource_id => $resource_id, class_project_id => undef, price_cents => 9000, currency => 'usd',
          units_per_acceptance => 2, per_booking_cap => 2 }, 'with the couples price and seats';
    is_deeply $v->{plans}, ['one_time'], 'paid once';
    is_deeply $v->{policies}, {
        refund => { kind => 'none', approval => 'none' },
        change => { kind => 'window', window_hours => 48, fee_cents => 0, targets => 'same_offer', price_difference => 'same_price_only', approval => 'none' },
        use    => { kind => 'optional_attendance' },
        expiry => { kind => 'end_of_occurrence' },
    }, 'and the couples policies';
};

# Before the second offer is published, for the subtest after it.
my $first_before = versions_of("Couple's wheel class");

subtest 'admin publishes the single seat offer over http' => sub {
    ok $resource_id, 'the seats resource exists' or return;
    my $t = client($admin);
    walk_to_publish( $t, {
        %DAY_ONE,
        resource       => { resource_mode => 'existing' },
        'offer-basics' => { resource_id => $resource_id, offer_name => 'Single seat' },
        'offer-price'  => { price_cents => 4500, currency => 'USD', units_per_acceptance => 1, per_booking_cap => 4 },
        'refund-policy' => { refund => 'full_until_cutoff', cutoff_hours => 48 },
    } ) or return;
    submit_step( $t, 'publish', action => 'publish' );

    my $v = current_version('Single seat');
    ok $v, 'the single seat offer has a current published version' or return;
    is_deeply { $v->%{qw( resource_id class_project_id price_cents currency units_per_acceptance per_booking_cap )} },
        { resource_id => $resource_id, class_project_id => undef, price_cents => 4500, currency => 'usd',
          units_per_acceptance => 1, per_booking_cap => 4 }, 'one seat of the same resource, up to 4 a booking';
    is_deeply $v->{plans}, ['one_time'], 'paid once';
    is_deeply $v->{policies}, {
        refund => { kind => 'full_until_cutoff', cutoff_hours => 48, approval => 'none' },
        change => { kind => 'window', window_hours => 48, fee_cents => 0, targets => 'same_offer', price_difference => 'same_price_only', approval => 'none' },
        use    => { kind => 'optional_attendance' },
        expiry => { kind => 'end_of_occurrence' },
    }, 'refunded in full until 48 hours before, with the day-one change, use and expiry';
    is $db->query('SELECT count(*) FROM resources')->array->[0], 1, 'both offers share the one resource';
};

subtest 'second offer leaves the first unchanged' => sub {
    ok scalar @$first_before, 'the first offer was published before the second';
    is_deeply versions_of("Couple's wheel class"), $first_before, 'its versions and terms are as they were';
};

subtest 'staff refused at offer publishing' => sub {
    my $runs = sub {
        $db->query( q{SELECT count(*) FROM workflow_runs r JOIN workflows w ON w.id = r.workflow_id
                       WHERE w.slug = 'offer-publishing'} )->array->[0];
    };
    my $before = $runs->();
    my $s      = client($staff);
    $s->get_ok( '/offer-publishing' => \%HOST )->status_is( 403, 'a GET is refused' );
    $s->post_ok( '/offer-publishing' => \%HOST => form => { csrf_token => csrf($s) } )
        ->status_is( 403, 'and so is a POST' )->content_isnt( 'CSRF token validation failed', 'by its role' );
    is $runs->(), $before, 'and no run is created';
};

subtest 'staff post to any step refused' => sub {
    ok $resource_id, 'the seats resource exists' or return;
    my $t     = client($admin);
    my @steps = walk_to_publish( $t, {
        %DAY_ONE,
        resource       => { resource_mode => 'existing' },
        'offer-basics' => { resource_id => $resource_id, offer_name => 'Staff target' },
        'offer-price'  => { price_cents => 100, currency => 'USD', units_per_acceptance => 1, per_booking_cap => 1 },
        'refund-policy' => { refund => 'none' },
    } );
    my $publish = $t->tx->res->dom->at('#workflow-content form')->attr('action');
    push @steps, $publish;
    my ($run_id) = $publish =~ m{/offer-publishing/([^/]+)/};
    my $snapshot = sub { $db->query( 'SELECT data, latest_step_id FROM workflow_runs WHERE id = ?', $run_id )->hash };
    my $before   = $snapshot->();
    my $versions = version_count();

    my $s     = client($staff);
    my $token = csrf($s);
    for my $url (@steps) {
        $s->post_ok( $url => \%HOST => form => {
            csrf_token    => $token,
            resource_mode => 'existing', resource_id => $resource_id, offer_name => 'Hijacked',
            price_cents   => 1, currency => 'USD', units_per_acceptance => 1, per_booking_cap => 1,
            one_time      => 'offered', percentage_of_sales => 'declined', refund => 'none',
            change        => 'none', use => 'none', expiry => 'never', action => 'publish',
        } )->status_is( 403, "a staff POST to $url is refused" )
            ->content_isnt( 'CSRF token validation failed', 'by its role' );
    }
    is_deeply $snapshot->(), $before, 'the run is unchanged';
    is version_count(), $versions, 'and nothing is published';
};

subtest 'more seats than capacity refused over http' => sub {
    ok $resource_id, 'the seats resource exists' or return;
    my $versions = version_count();
    my $t        = client($admin);
    $t->get_ok( '/offer-publishing' => \%HOST )->status_is(200);
    submit_step( $t, 'resource', resource_mode => 'existing' );
    submit_step( $t, 'offer-basics', resource_id => $resource_id, offer_name => 'Eleven seats' );
    my $price = refused_step( $t, 'offer-price',
        price_cents => 9000, currency => 'USD', units_per_acceptance => 11, per_booking_cap => 1 );

    # Straight to publish, past the refused price.
    ( my $publish = $price ) =~ s{/offer-price\z}{/publish};
    $t->post_ok( $publish => \%HOST => form => { action => 'publish', csrf_token => csrf($t) } );
    is version_count(), $versions, 'nothing is published';
    is $db->query(q{SELECT count(*) FROM offers WHERE name = 'Eleven seats'})->array->[0], 0, 'not even an offer';
};

subtest 'foreign occurrence binding refused over http' => sub {
    my $t = client($admin);
    $t->get_ok( '/offer-publishing' => \%HOST )->status_is(200);
    refused_step( $t, 'resource',
        resource_mode => 'create', resource_name => 'Foreign seats', resource_kind => 'finite',
        capacity      => 10,       event_id      => $foreign );
    is $db->query(q{SELECT count(*) FROM resources WHERE name = 'Foreign seats'})->array->[0], 0,
        'no resource is created in the tenant';
    is $other->query('SELECT count(*) FROM resources')->array->[0], 0, 'nor in the other tenant';
};

subtest 'replayed publish creates no second version' => sub {
    ok $resource_id, 'the seats resource exists' or return;
    my $t = client($admin);
    walk_to_publish( $t, {
        %DAY_ONE,
        resource       => { resource_mode => 'existing' },
        'offer-basics' => { resource_id => $resource_id, offer_name => 'Replayed seat' },
        'offer-price'  => { price_cents => 4500, currency => 'USD', units_per_acceptance => 1, per_booking_cap => 1 },
        'refund-policy' => { refund => 'none' },
    } ) or return;
    my $publish = submit_step( $t, 'publish', action => 'publish' );
    my $versions = version_count();
    is scalar versions_of('Replayed seat')->@*, 1, 'one version is published';

    $t->post_ok( $publish => \%HOST => form => { action => 'publish', csrf_token => csrf($t) } );
    isnt $t->tx->res->body, 'CSRF token validation failed', 'the replay passes the CSRF check';
    is scalar versions_of('Replayed seat')->@*, 1, 'the replay publishes no second version';
    is $db->query(q{SELECT count(*) FROM offers WHERE name = 'Replayed seat'})->array->[0], 1, 'nor a second offer';
    is version_count(), $versions, 'nor any other version';
};

done_testing;
