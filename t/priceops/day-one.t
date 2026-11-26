#!/usr/bin/env perl
# ABOUTME: The PriceOps day-one acceptance test: registry sells only Solo, SACP signs up holding it, sets up a class,
# ABOUTME: and a visitor's booking holds seats with Solo's 2.5% fee quoted, through the real workflows, with no Stripe call.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use File::Spec;
use POSIX qw( strftime );
use Test::Registry::DB;
use Test::Registry::Mojo;
use Test::Registry::Fixtures;
use Mojo::URL;
use Test::Registry::Helpers qw( authenticate_as import_all_workflows join_tenant );
use Test::Registry::Offers qw( offer_terms );
use Test::Registry::Async qw( settle );
use Test::Registry::StripeWebhook;
use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::Location;
use Registry::DAO::Project;
use Registry::DAO::Event;
use Registry::DAO::Resource;
use Registry::DAO::Offer;
use Registry::DAO::Payment;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowRun;
use Registry::DAO::Entitlement;
use Registry::PriceOps::Hold;
use Registry::Terms;
use Registry::PriceOps::PlatformTerms qw( platform_terms_for_tenant );
use Registry::Utility::WorkflowProcessor;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
$ENV{DB_URL} = $test_db->uri;
import_all_workflows($dao);

my $SOLO = $Registry::PriceOps::PlatformTerms::SOLO_OFFER_ID;
my @IN_STUDIO = qw( in-studio-booking in-studio-class-setup in-studio-day-view in-studio-schedule );

# What signup offers a tenant: the platform's current published offers to tenants.
sub offers_to_tenants () { Registry::PriceOps::PlatformTerms::platform_offers_to_tenants($db) }

subtest 'registry is the one platform tenant and publishes only solo' => sub {
    ok( Registry::DAO::Tenant->find( $db, { slug => 'registry' } ), 'the platform tenant is registry' );
    ok( !Registry::DAO::Tenant->find( $db, { slug => 'registry-platform' } ), 'and there is no registry-platform row' );
    my $offers = offers_to_tenants();
    is scalar @$offers, 1, 'one offer to tenants is published';
    is $offers->[0]{offer_id}, $SOLO, 'Solo';
    is $offers->[0]{amount_cents}, 0, 'at $0';
    is $offers->[0]{fraction}, '0.025', 'and 2.5% of sales';
};

# SACP signs up as any studio does: the tenant-signup workflow, accepting the
# Solo version the review page offers; then sql/seed/sacp-tenant.sql adds its data.
my ($signup) = Registry::DAO::Workflow->find( $db, { slug => 'tenant-signup' } );

sub sign_up ( $slug, $name ) {
    my $processor = Registry::WorkflowProcessor->new( dao => $db );
    my $run       = $processor->new_run( $signup, {
        name => $name, subdomain => $slug, admin_name => "Admin $slug", admin_email => "${slug}_admin\@test.example",
        admin_username => "${slug}_admin", admin_user_type => 'admin', profile => { name => $name, slug => $slug },
    } );
    $processor->process_workflow_run_step( $run, $signup->get_step( $db, { slug => $_ } ), {} ) for qw( profile users );
    $processor->process_workflow_run_step( $run, $signup->get_step( $db, { slug => 'review' } ),
        { offer_version => offers_to_tenants()->[0]{id} } );
    $processor->process_workflow_run_step( $run, $signup->get_step( $db, { slug => 'complete' } ), {} );
    $db->query('SET search_path = registry, public');
    return Registry::DAO::Tenant->find( $db, { slug => $slug } );
}

my $sacp = sign_up( 'sacp', 'Super Awesome Cool Pottery' );
my ( $uri, $seed ) = ( $test_db->uri, File::Spec->rel2abs('sql/seed/sacp-tenant.sql') );
is system(qq{psql -q -v ON_ERROR_STOP=1 "$uri" -f "$seed" >/dev/null 2>&1}), 0, 'the SACP seed runs after signup';

subtest 'sacp holds solo from registry' => sub {
    ok $sacp, 'signup created sacp';
    my @held = Registry::DAO::Entitlement->held_by( $db, $sacp->id );
    is scalar @held, 1, 'it holds one entitlement';
    is $held[0]->offer_version_id, offers_to_tenants()->[0]{id}, "Solo's current version";
    is $held[0]->payment_plan_id, 'revenue_share', 'under its revenue-share plan';
    my $terms = platform_terms_for_tenant( $db, 'sacp' );
    is $terms->{id}, $held[0]->offer_version_id, 'which is the platform terms sacp is charged under';
    is $terms->{fraction}, '0.025', 'at 2.5%';
    ok( Registry::DAO::Entitlement->may_run( $db, $sacp->id, $_ ), "and sacp may run $_" ) for @IN_STUDIO;
};

# SACP's connected account, as Connect onboarding leaves it; no Stripe call is made in this file.
$sacp->update( $db, { stripe_connect_account_id => 'acct_day_one_sacp',
    stripe_charges_enabled => 1, stripe_details_submitted => 1 } );

my $sdao = Registry::DAO->new( url => $test_db->uri, schema => 'sacp' );
my $sdb  = $sdao->db;
my %SACP = ( Host => 'sacp.localhost' );

sub client ( $user = undef ) {
    my $t = Test::Registry::Mojo->new('Registry');
    authenticate_as( $t, $user ) if $user;
    return $t;
}

# Submits the page's form with %fields on $host and opens the screen it redirects to.
sub submit ( $t, $fields, $host = \%SACP ) {
    my $form = $t->tx->res->dom->at('#workflow-content form') or return fail 'no form';
    $t->post_ok( $form->attr('action') => $host => form => $fields )->status_is(302);
    my $next = $t->tx->res->headers->location;
    $t->get_ok( $next => $host )->status_is(200);
    return $next;
}

my $day     = strftime '%Y-%m-%d', gmtime( time + 7 * 86400 );
my $studio  = Registry::DAO::Location->find( $sdb, { slug => 'sacp_studio' } );
my $booker  = Test::Registry::Fixtures::create_user( $sdao,
    { username => 'day_one_booker', name => 'Day One Booker', email => 'booker@day-one.test', user_type => 'parent' } );
my ( $occurrence, $run );

subtest 'booking holds seats and quotes the solo fee' => sub {
    my $admin = Registry::DAO::User->find( $db, { username => 'sacp_admin' } );
    ok $studio, 'the seed gave sacp its studio';

    # An SACP admin sets up a class and its one-seat offer under SACP's policies.
    my $t = client($admin);
    $t->get_ok( '/in-studio-class-setup' => \%SACP )->status_is(200);
    submit( $t, $_ ) for
        { class_mode => 'create', class_name => 'Wheel throwing', location_id => $studio->id, seats_per_occurrence => 6 },
        { offer_name => 'One seat' },
        { price_cents => 4500, currency => 'USD', units_per_acceptance => 1, per_booking_cap => 4 },
        { one_time => 'offered' }, { refund => 'none' },
        { change => 'window', window_hours => 48, fee_cents => 1000, targets => 'same_offer' },
        { use => 'optional_attendance' }, { expiry => 'end_of_occurrence' };
    like submit( $t, { action => 'publish' } ), qr{/complete\z}, 'class setup publishes the class\'s offer';
    my ($class) = Registry::DAO::Project->find( $sdb, { name => 'Wheel throwing' } ) or return fail 'no class';

    # ... and schedules it: one occurrence a week out.
    $t->get_ok( '/in-studio-schedule' => \%SACP )->status_is(200);
    like submit( $t, { class_project_id => $class->id, location_id => '', teacher_id => $admin->id,
        weekdays => [qw( monday tuesday wednesday thursday friday saturday sunday )], start_time => '10:00',
        duration => 90, first_date => $day, last_date => $day } ), qr{/complete\z}, 'occurrences are generated';
    my @events = Registry::DAO::Event->find( $sdb, { project_id => $class->id } );
    is scalar @events, 1, 'one occurrence' or return;
    ($occurrence) = Registry::DAO::Resource->find( $sdb, { event_id => $events[0]->id } ) or return fail "no occurrence";
    is $occurrence->free_units($sdb), 6, 'with its six seats free';

    # A signed-in visitor books two seats on the booking page.
    my $v = client($booker);
    $v->get_ok( '/in-studio-booking' => \%SACP )->status_is(200)->content_like( qr/Wheel throwing/, 'a visitor sees the class' );
    like submit( $v, { occurrence_id => $occurrence->id } ), qr{/offer\z}, 'chooses its occurrence';
    my $version = $v->tx->res->dom->at('#workflow-content input[name="offer_version_id"]') or return fail 'no offer';
    $v->content_like( qr/One seat/, 'sees its offer' )->content_like( qr/\$45\.00/, 'at $45' );
    like submit( $v, { offer_version_id => $version->attr('value'), count => 2, agree_to_terms => 1,
        terms_version_shown => Registry::Terms::VERSION } ), qr{/account\z}, 'chooses two seats and agrees to the terms';
    like submit( $v, { action => 'continue_logged_in' } ), qr{/hold\z}, 'continues signed in';
    $v->content_like( qr/Total: \$90\.00/, 'and is shown the total' );
    my $payment_url = submit( $v, {} );
    my ($run_id) = $payment_url =~ m{/in-studio-booking/([0-9a-f-]{36})/payment\z} or return fail 'not at payment';

    is $occurrence->free_units($sdb), 4, 'the two seats are held';
    $run = Registry::DAO::WorkflowRun->find( $sdb, { id => $run_id } );
    my $hold = Registry::PriceOps::Hold->find( $sdb, { id => $run->data->{booking_hold}{hold_id} }, { -asc => 'id' } );
    is $hold->state, 'held', 'by a live hold';
    is $hold->units, 2, 'of two seats';

    # The quote: the payment the payment step writes, and the intent it would send Stripe.
    my $workflow = Registry::DAO::Workflow->find( $sdb, { slug => 'in-studio-booking' } );
    my $owed     = $workflow->get_step( $sdb, { slug => 'payment' } )->owed_payment( $sdb, $run );
    my $payment  = $owed->{payment} or return fail "payment refused: @{ $owed->{errors} // [] }";
    my $solo     = platform_terms_for_tenant( $db, 'sacp' );
    is $payment->amount_cents, 9000, 'the amount is two seats at $45';
    is $payment->metadata->{stripe_account_id}, 'acct_day_one_sacp', "charged on sacp's account";
    is $payment->metadata->{platform_offer_version_id}, $solo->{id}, "quoted under sacp's Solo entitlement";
    is $payment->metadata->{revenue_share_fraction}, '0.025', 'at its 2.5%';
    my $intent = $payment->_intent_params( $sdb, {} );
    is $intent->{application_fee_amount}, 225, 'the quoted fee is 2.5% of $90: $2.25';
    ok !exists $intent->{'transfer_data[destination]'} && !exists $intent->{on_behalf_of},
        'a direct charge: no transfer_data, no on_behalf_of';
};

subtest 'studio and empire not published' => sub {
    is_deeply [ map { $_->{name} } offers_to_tenants()->@* ], ['Solo'], 'the platform offers tenants Solo alone';

    # Signup's review page, walked over HTTP on the platform's host.
    my $t = client();
    $t->post_ok('/tenant-signup')->status_is(302);
    $t->post_ok( $t->tx->res->headers->location => form => { name => 'Looking Studio', billing_email => 'look@day-one.test' } )
        ->status_is(302);
    $t->post_ok( $t->tx->res->headers->location => form => { admin_name => 'Look', admin_email => 'look_admin@day-one.test',
        admin_username => 'look_admin', admin_user_type => 'admin' } )->status_is(302);
    $t->get_ok( $t->tx->res->headers->location )->status_is(200);
    my $dom = $t->tx->res->dom;
    is_deeply $dom->find('input[name="offer_version"]')->map( attr => 'value' )->to_array, [ offers_to_tenants()->[0]{id} ],
        'signup lists one plan to choose';
    my $labels = $dom->find('label[for^="offer-"]')->map('all_text')->join(' ');
    like $labels, qr/Solo/, 'Solo';
    unlike $labels, qr/Studio|Empire/, 'and neither Studio nor Empire';
};

# A tenant that never accepted Solo, though it holds copies of the workflows
# and a ready Stripe account, with a priced class offer and an occurrence.
subtest 'tenant without solo cannot charge' => sub {
    my $tenant = Registry::DAO::Tenant->provision( $db, { name => 'No Solo Studio', slug => 'no_solo', users => [],
        stripe_connect_account_id => 'acct_day_one_no_solo', stripe_charges_enabled => 1, stripe_details_submitted => 1 } );
    $db->query('SET search_path = registry, public');
    my $ndao = Registry::DAO->new( url => $test_db->uri, schema => 'no_solo' );
    my $ndb  = $ndao->db;
    import_all_workflows($ndao);
    ok !Registry::DAO::Entitlement->held_by( $db, $tenant->id ), 'it holds no entitlement';

    my $t = client();
    $t->get_ok( '/in-studio-booking' => { Host => 'no_solo.localhost' } );
    isnt $t->tx->res->code, 200, 'its booking page is refused';

    my $room   = Test::Registry::Fixtures::create_location( $ndb, { name => 'Room', slug => 'room', time_zone => 'America/New_York' } );
    my $who    = Test::Registry::Fixtures::create_user( $ndao,
        { username => 'no_solo_booker', name => 'No Solo Booker', email => 'b@no-solo.test', user_type => 'parent' } );
    my $class  = Registry::DAO::Project->create( $ndb, { name => 'Unpriced', seats_per_occurrence => 6 } );
    my $event  = Registry::DAO::Event->create( $ndb, { project_id => $class->id, location_id => $room->id,
        teacher_id => $who->id, time => \q{now() + interval '7 days'}, duration => 90, capacity => 6, status => 'published' } );
    my $seats  = Registry::DAO::Resource->for_occurrence( $ndb, $event->id );
    my $version = Registry::DAO::Offer->create( $ndb, { name => 'One seat' } )->draft( $ndb, offer_terms( undef,
        class_project_id => $class->id, price_cents => 4500,
        policies => { refund => { kind => 'none' }, use => { kind => 'optional_attendance' },
                      expiry => { kind => 'end_of_occurrence' } } ) )->publish($ndb);

    my $workflow = Registry::DAO::Workflow->find( $ndb, { slug => 'in-studio-booking' } );
    my $run = Registry::WorkflowProcessor->new( dao => $ndao )->new_run( $workflow,
        { user => { id => $who->id, name => $who->name }, user_id => $who->id, __tenant_slug => 'no_solo' } );
    for (
        [ occurrence => { occurrence_id => $seats->id } ],
        [ offer      => { offer_version_id => $version->id, count => 1, agree_to_terms => 1,
                          terms_version_shown => Registry::Terms::VERSION } ],
        [ account    => { action => 'continue_logged_in' } ],
        [ hold       => {} ],
    ) {
        my $r = $run->process( $ndb, $workflow->get_step( $ndb, { slug => $_->[0] } ), $_->[1] );
        return fail "$_->[0] refused: @{ $r->{errors} }" if ref $r eq 'HASH' && $r->{errors};
    }

    my @warned;
    my $out = do {
        local $SIG{__WARN__} = sub { push @warned, @_ };
        settle( $run->process( $ndb, $workflow->get_step( $ndb, { slug => 'payment' } ), {} ) );
    };
    like "@{ $out->{errors} // [] }", qr/cannot be taken right now\. Nothing has been charged/, 'the priced booking is refused';
    like "@warned", qr/'no_solo' holds no platform entitlement/, 'because it holds no platform entitlement';
    is scalar( my @none = Registry::DAO::Payment->find( $ndb, {} ) ), 0, 'and no payment is written, so nothing is charged';
};

subtest 'other tenant cannot see sacp booking' => sub {
    local $ENV{STRIPE_CONNECT_WEBHOOK_SECRET} = 'whsec_day_one_connect_local';

    # The visitor's payment succeeds on SACP's account: as Stripe would report it
    # to the Connect endpoint, signed here. The run driver makes the booking.
    my $payment = Registry::DAO::Payment->find( $sdb, { id => $run->data->{owed_payment_id} } )
        or return fail 'no payment from the booking';
    $payment->_record_intent( $sdb, { id => 'pi_day_one_' . $payment->id, client_secret => 'x_secret' } );
    my $t = client();
    Test::Registry::StripeWebhook::post_connect( $t, {
        type => 'payment_intent.succeeded', account => 'acct_day_one_sacp',
        data => { object => { id => 'pi_day_one_' . $payment->id, amount => 9000, application_fee_amount => 225,
            metadata => { payment_id => $payment->id, tenant_slug => 'sacp' } } },
    } )->status_is(200);
    my $jobs = $t->app->minion->jobs( { tasks => ['continue_workflow_run'], states => ['inactive'] } );
    while ( my $job = $jobs->next ) { $t->app->minion->perform_jobs( { id => $job->{id} } ) }
    my ($booking) = Registry::DAO::Entitlement->created_by_payment( $sdb, $payment->id ) or return fail 'no booking';
    is $booking->holder_user_id, $booker->id, "the booker's entitlement exists";

    # A string: a Mojo::URL is made absolute by the first client to use it.
    my $url = Mojo::URL->new('/in-studio-day-view')->query( location_id => $studio->id, day => $day )->to_string;
    my $mine = client( Registry::DAO::User->find( $db, { username => 'sacp_admin' } ) );
    $mine->get_ok( $url => \%SACP )->status_is(200)->content_like( qr/Day One Booker/, "sacp's admin sees the booking" );
    ok $mine->tx->res->dom->at(qq{[data-entitlement="${\ $booking->id }"]}), 'its entitlement is listed';
    my $form = $mine->tx->res->dom->at(qq{[data-occurrence="${\ $occurrence->id }"] form})
        or return fail 'no attendance form';

    sign_up( 'clay_other', 'Clay Other' );
    my $staff = Test::Registry::Fixtures::create_user( $dao,
        { username => 'clay_other_staff', name => 'Other Staff', email => 'staff@clay-other.test', user_type => 'staff' } );
    join_tenant( $dao, $staff, 'staff', 'clay_other' );
    my %OTHER = ( Host => 'clay_other.localhost' );
    for ( [ admin => Registry::DAO::User->find( $db, { username => 'clay_other_admin' } ) ], [ staff => $staff ] ) {
        my ( $role, $user ) = @$_;
        my $c = client($user);
        $c->get_ok( $url => \%SACP )->status_is( 403, "the other tenant's $role is refused sacp's day view" )
            ->content_unlike( qr/Day One Booker/, 'and shown no booking' );
        $c->post_ok( $form->attr('action') => \%SACP => form => { entitlement_id => $booking->id,
            occurrence_id => $occurrence->id } )->status_is( 403, 'nor may they mark it' );
    }
    # On its own host, naming SACP's studio and booking finds neither.
    my $c = client( Registry::DAO::User->find( $db, { username => 'clay_other_admin' } ) );
    $c->get_ok( $url => \%OTHER )->status_is( 400, "its own day view does not know sacp's studio" )
        ->content_unlike( qr/Day One Booker/, 'and shows no booking' );
    my $odb = Registry::DAO->new( url => $test_db->uri, schema => 'clay_other' )->db;
    ok !Registry::DAO::Entitlement->find( $odb, { id => $booking->id } ), "nor does its data hold the booker's entitlement";
    ok !Registry::DAO::Entitlement->held_by( $odb, $booker->id ), 'or any held by the booker';
};

done_testing;
