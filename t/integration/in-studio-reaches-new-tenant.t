#!/usr/bin/env perl
# ABOUTME: A studio signing up through tenant-signup accepts Solo's current version and so holds the in-studio run rights and copies.
# ABOUTME: Its admin then sets up and schedules a class and a visitor reaches booking; the grant is the version's stored set.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use POSIX qw( strftime );
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( authenticate_as import_all_workflows );
use Registry;
use Registry::DAO;
use Registry::DAO::Workflow;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::Entitlement;
use Registry::DAO::Offer;
use Registry::DAO::OfferVersion;
use Registry::PriceOps::PlatformTerms ();
use Registry::Utility::WorkflowProcessor;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
$ENV{DB_URL} = $test_db->uri;
import_all_workflows($dao);

# The approved design's five in-studio workflows (row 12).
my @IN_STUDIO = qw( entitlement-change in-studio-booking in-studio-class-setup in-studio-day-view in-studio-schedule );

my ($signup) = Registry::DAO::Workflow->find( $db, { slug => 'tenant-signup' } );

# What the signup review page lists: the platform's one current offer to tenants.
my ($solo) = map { $_->{id} } Registry::PriceOps::PlatformTerms::platform_offers_to_tenants($db)->@*;

# Signs a studio $slug up through the tenant-signup workflow, choosing what
# the review page preselects. Returns the tenant.
sub sign_up ($slug) {
    my $processor = Registry::WorkflowProcessor->new( dao => $db );
    my $run       = $processor->new_run( $signup, {
        name           => "Studio $slug", subdomain => $slug, admin_name => "Admin $slug",
        admin_email    => "${slug}_admin\@test.example", admin_username => "${slug}_admin",
        admin_user_type => 'admin', profile => { name => "Studio $slug", slug => $slug },
    } );
    $processor->process_workflow_run_step( $run, $signup->get_step( $db, { slug => $_ } ), {} ) for qw( profile users );
    $processor->process_workflow_run_step( $run, $signup->get_step( $db, { slug => 'review' } ), { offer_version => $solo } );
    $processor->process_workflow_run_step( $run, $signup->get_step( $db, { slug => 'complete' } ), {} );
    $db->query('SET search_path = registry, public');
    return Registry::DAO::Tenant->find( $db, { slug => $slug } );
}

sub held ($tenant) {
    return $db->query( 'SELECT offer_version_id FROM registry.entitlements WHERE holder_tenant_id = ? ORDER BY 1',
        $tenant->id )->arrays->map( sub { $_->[0] } )->to_array;
}

# Workflow $slug's step slugs, in schema $schema, or undef when it holds none.
sub steps ( $schema, $slug ) {
    my $q = $db->dbh->quote_identifier($schema);
    return undef unless $db->query( "SELECT 1 FROM $q.workflows WHERE slug = ?", $slug )->rows;
    return $db->query( "SELECT s.slug FROM $q.workflow_steps s JOIN $q.workflows w ON w.id = s.workflow_id
                         WHERE w.slug = ? ORDER BY s.slug", $slug )->arrays->map( sub { $_->[0] } )->to_array;
}

my $studio = sign_up('clay_new');

subtest 'a studio signing up holds the in-studio run rights and copies' => sub {
    ok $solo, 'signup offers a current Solo version';
    is_deeply held($studio), [$solo], 'the new studio holds Solo\'s current version';
    for my $slug (@IN_STUDIO) {
        ok Registry::DAO::Entitlement->may_run( $db, $studio->id, $slug ), "it holds the run right to $slug";
        is_deeply steps( 'clay_new', $slug ), steps( 'registry', $slug ), "and a copy of $slug with its steps";
    }
};

# A tenant with an empty schema, holding nothing.
sub bare_tenant ($slug) {
    my $tenant = Registry::DAO::Tenant->create( $db, { name => "Studio $slug", slug => $slug } );
    $db->query( 'SELECT clone_schema(dest_schema => ?)', $slug );
    $db->query('SET search_path = registry, public');
    return $tenant;
}

sub workflows_in ($schema) {
    my $q = $db->dbh->quote_identifier($schema);
    return $db->query("SELECT slug FROM $q.workflows ORDER BY slug")->arrays->map( sub { $_->[0] } )->to_array;
}

# perigrin: "a later offer maybe only offers *some* workflows (e.g in-studio
# classes only)". What a version grants is the set it stores, nothing more.
subtest 'a version listing only the in-studio workflows grants only those' => sub {
    my $offer = Registry::DAO::Offer->create( $db, { name => 'In-studio classes only' } );
    my $run   = sub ($slug) { $db->query( 'SELECT id FROM registry.resources WHERE name = ?', "run:$slug" )->array->[0] };
    my $some  = $offer->draft( $db, {
        resource_ids  => [ map { $run->($_) } @IN_STUDIO ], price_cents => 0, units_per_acceptance => 1,
        per_booking_cap => 1, policies => { refund => { kind => 'none' } },
        payment_plans => [ { id => 'share', kind => 'percentage_of_sales', fraction => 0.01 } ],
    } )->publish($db);
    my $tenant = bare_tenant('in_studio_only');

    Registry::DAO::Tenant->accept_platform_offer( $db, $tenant,
        { offer_version_id => $some->id, payment_plan_id => 'share' } );

    is_deeply workflows_in('in_studio_only'), [@IN_STUDIO], 'the tenant holds copies of the in-studio workflows alone';
    ok( Registry::DAO::Entitlement->may_run( $db, $tenant->id, $_ ), "it may run $_" ) for @IN_STUDIO;
    ok( !Registry::DAO::Entitlement->may_run( $db, $tenant->id, $_ ), "but not $_, which registry holds too" )
        for qw( session-creation program-setup tenant-storefront admin-dashboard );
};

# Requests on the studio's own host.
my %HOST = ( Host => 'clay_new.localhost' );

sub client ( $user = undef ) {
    my $t = Test::Registry::Mojo->new('Registry');
    authenticate_as( $t, $user ) if $user;
    return $t;
}

# Submits the page's form with %fields and opens the screen it redirects to.
sub submit ( $t, %fields ) {
    my $form = $t->tx->res->dom->at('#workflow-content form') or return fail 'no form';
    $t->post_ok( $form->attr('action') => \%HOST => form => \%fields )->status_is(302);
    my $next = $t->tx->res->headers->location;
    $t->get_ok( $next => \%HOST )->status_is(200);
    return $next;
}

subtest 'its admin sets up and schedules a class and a visitor reaches booking' => sub {
    my $tdb   = Registry::DAO->new( url => $test_db->uri, schema => 'clay_new' )->db;
    my $room  = Test::Registry::Fixtures::create_location( $tdb, { name => 'Wheel room', slug => 'wheel-room' } );
    my $admin = Registry::DAO::User->find( $db, { username => 'clay_new_admin' } );

    my $t = client($admin);
    $t->get_ok( '/in-studio-class-setup' => \%HOST )->status_is(200);
    submit( $t, class_mode => 'create', class_name => 'Throwing', location_id => $room->id, seats_per_occurrence => 6 );
    submit( $t, offer_name => 'One seat' );
    submit( $t, @$_ ) for
        [ price_cents => 4500, currency => 'USD', units_per_acceptance => 1, per_booking_cap => 4 ],
        [ one_time => 'offered' ], [ refund => 'none' ],
        [ change => 'window', window_hours => 48, fee_cents => 1000, targets => 'same_offer' ],
        [ use => 'optional_attendance' ], [ expiry => 'end_of_occurrence' ];
    like submit( $t, action => 'publish' ), qr{/complete\z}, 'class setup publishes the class\'s offer';
    my $class = $tdb->query(q{SELECT id FROM projects WHERE name = 'Throwing'})->hash
        or return fail 'no class in the studio\'s schema';

    $t->get_ok( '/in-studio-schedule' => \%HOST )->status_is(200);
    my $day = sub ($n) { strftime '%Y-%m-%d', gmtime( time + $n * 86400 ) };
    like submit( $t, class_project_id => $class->{id}, location_id => '', teacher_id => $admin->id,
        weekdays => [qw( monday tuesday wednesday thursday friday saturday sunday )], start_time => '10:00',
        duration => 90, first_date => $day->(7), last_date => $day->(7) ), qr{/complete\z}, 'occurrences are generated';
    my $occurrence = $tdb->query( q{SELECT r.id FROM resources r JOIN events e ON e.id = r.event_id
                                     WHERE e.project_id = ?}, $class->{id} )->hash or return fail 'no occurrence';

    my $visitor = client();
    $visitor->get_ok( '/in-studio-booking' => \%HOST )->status_is(200)->content_like( qr/Throwing/, 'a visitor sees the class' );
    like submit( $visitor, occurrence_id => $occurrence->{id} ), qr{/offer\z}, 'and chooses its occurrence';
    $visitor->content_like( qr/One seat/, 'the booking page offers its seats' )->content_like(qr/\$45\.00/);
};

done_testing;
