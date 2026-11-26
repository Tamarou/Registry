# ABOUTME: Gated real-Stripe end of the day-one journey: SACP, signed up holding Solo, takes a booking as a direct charge.
# ABOUTME: The intent on SACP's account carries Solo's 2.5% fee and no transfer_data; the Connect webhook books the seats.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::StripeConnect;
use Test::Registry::StripeConfirm;
use Test::Registry::StripeWebhook;
use Test::Registry::DB;
use Test::Registry::Mojo;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( import_all_workflows );
use Test::Registry::Offers qw( offer_terms );
use Test::Registry::Async qw( settle );

use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::Payment;
use Registry::DAO::Project;
use Registry::DAO::Event;
use Registry::DAO::Offer;
use Registry::DAO::Resource;
use Registry::DAO::Entitlement;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowRun;
use Registry::PriceOps::PlatformTerms qw( platform_terms_for_tenant );
use Registry::Utility::WorkflowProcessor;
use Registry::Terms;

plan skip_all => 'STRIPE_SECRET_KEY (sk_test_) not set'
    unless Test::Registry::StripeConnect::available();

# DO NOT localise STRIPE_SECRET_KEY: the real test key must reach the payment step.
# The sale is on SACP's account, so Stripe reports it to the Connect endpoint,
# signed with the Connect secret; the event is signed here with a local one.
local $ENV{STRIPE_CONNECT_WEBHOOK_SECRET} = 'whsec_day_one_connect_local';
local $ENV{REGISTRY_BASE_DOMAINS}         = 'tinyartempire.com,localhost';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
import_all_workflows($dao);

my $t      = Test::Registry::Mojo->new('Registry');
my $minion = $t->app->minion;

# SACP signs up as any studio does: tenant-signup, accepting the Solo version
# the review page offers, which gives it the in-studio workflows.
my ($signup) = Registry::DAO::Workflow->find( $db, { slug => 'tenant-signup' } );
my $solo_offered = Registry::PriceOps::PlatformTerms::platform_offers_to_tenants($db)->[0]{id};
{
    my $processor = Registry::WorkflowProcessor->new( dao => $db );
    my $run       = $processor->new_run( $signup, {
        name => 'Super Awesome Cool Pottery', subdomain => 'sacp', admin_name => 'Victoria',
        admin_email => "sacp_live_admin_$$\@test.example", admin_username => "sacp_live_admin_$$",
        admin_user_type => 'admin', profile => { name => 'Super Awesome Cool Pottery', slug => 'sacp' },
    } );
    $processor->process_workflow_run_step( $run, $signup->get_step( $db, { slug => $_ } ), {} ) for qw( profile users );
    $processor->process_workflow_run_step( $run, $signup->get_step( $db, { slug => 'review' } ),
        { offer_version => $solo_offered } );
    $processor->process_workflow_run_step( $run, $signup->get_step( $db, { slug => 'complete' } ), {} );
    $db->query('SET search_path = registry, public');
}
my $sacp = Registry::DAO::Tenant->find( $db, { slug => 'sacp' } ) or BAIL_OUT('signup made no sacp tenant');
my $solo = platform_terms_for_tenant( $db, 'sacp' );
is $solo->{id}, $solo_offered, 'sacp holds the Solo version signup offered';

note 'Waiting for charges_enabled on ready Stripe test account (up to 180s)...';
my $acct = Test::Registry::StripeConnect::ready_account();
like $acct, qr/^acct_/, 'ready account id obtained';
$sacp->update( $db, { stripe_connect_account_id => $acct, stripe_charges_enabled => 1, stripe_details_submitted => 1 } );

my $sdao = Registry::DAO->new( url => $test_db->uri, schema => 'sacp' );
my $sdb  = $sdao->db;

# A class with one occurrence a week out, and a $45 one-seat offer under SACP's policies.
my $room = Test::Registry::Fixtures::create_location( $sdb,
    { name => 'SACP studio', slug => 'sacp-live-studio', time_zone => 'America/New_York' } );
my %user = map {
    $_ => Registry::DAO::User->create( $sdb, {
        username => "sacp_live_${_}_$$", email => "sacp_live_${_}_$$\@test.example",
        name => "SACP Live \u$_", user_type => $_ eq 'teacher' ? 'staff' : 'parent' } )
} qw( booker teacher );
my $class = Registry::DAO::Project->create( $sdb,
    { name => 'Wheel throwing', seats_per_occurrence => 6, metadata => { location_id => $room->id } } );
my $event = Registry::DAO::Event->create( $sdb, {
    project_id => $class->id, location_id => $room->id, teacher_id => $user{teacher}->id,
    time => \q{now() + interval '7 days'}, duration => 90, capacity => 6, status => 'published' } );
my $occurrence = Registry::DAO::Resource->for_occurrence( $sdb, $event->id );
my $version    = Registry::DAO::Offer->create( $sdb, { name => 'One seat' } )
    ->draft( $sdb, offer_terms( undef, class_project_id => $class->id, price_cents => 4500, per_booking_cap => 4,
        policies => {
            refund => { kind => 'none' },
            change => { kind => 'window', window_hours => 48, fee_cents => 1000, targets => 'same_offer' },
            use    => { kind => 'optional_attendance' },
            expiry => { kind => 'end_of_occurrence' },
        } ) )
    ->publish($sdb);

my $workflow = $sdao->find( Workflow => { slug => 'in-studio-booking' } );
sub step ($slug) { $workflow->get_step( $sdb, { slug => $slug } ) }

# Performs the queued run drivers, as Minion's worker would.
sub drive () {
    my $jobs = $minion->jobs( { tasks => ['continue_workflow_run'], states => ['inactive'] } );
    while ( my $job = $jobs->next ) { $minion->perform_jobs( { id => $job->{id} } ) }
}

subtest 'direct charge on sacp account with the solo fee' => sub {
    # The visitor chose two seats, agreed to the terms, signed in and holds them.
    my $u   = $user{booker};
    my $run = Registry::WorkflowProcessor->new( dao => $sdao )->new_run( $workflow,
        { user => { id => $u->id, name => $u->name }, user_id => $u->id, __tenant_slug => 'sacp' } );
    for (
        [ occurrence => { occurrence_id => $occurrence->id } ],
        [ offer      => { offer_version_id => $version->id, count => 2,
                          agree_to_terms => 1, terms_version_shown => Registry::Terms::VERSION } ],
        [ account    => { action => 'continue_logged_in' } ],
        [ hold       => {} ],
    ) {
        my $r = $run->process( $sdb, step( $_->[0] ), $_->[1] );
        return fail "$_->[0] refused: @{ $r->{errors} }" if ref $r eq 'HASH' && $r->{errors};
    }
    is $occurrence->free_units($sdb), 4, 'two seats are held';

    my $first = settle( $run->process( $sdb, step('payment'), {} ) );
    ok $first->{stay}, 'the payment step waits for the card';
    is $first->{template_data}{step_data}{stripe_account}, $acct, "on sacp's account";
    my $payment_id = Registry::DAO::WorkflowRun->find( $sdb, { id => $run->id } )->data->{owed_payment_id};
    my $intent_id  = Registry::DAO::Payment->find( $sdb, { id => $payment_id } )->stripe_payment_intent_id;
    like $intent_id, qr/^pi_/, 'a real intent was created';

    is Test::Registry::StripeConfirm::confirm( $intent_id, undef, $acct )->{status}, 'succeeded',
        'Stripe takes the test card on sacp\'s account';
    my $intent = Test::Registry::StripeConfirm::_get( "/payment_intents/$intent_id", $acct );
    is $intent->{id}, $intent_id, 'the intent is retrieved with sacp\'s Stripe-Account';
    is $intent->{amount}, 9000, 'for two seats at $45';
    is $intent->{application_fee_amount}, 225, "with Solo's 2.5% application fee";
    ok !$intent->{transfer_data}, 'and no transfer_data';

    # Stripe reports the sale to the Connect endpoint; the run driver completes the booking.
    Test::Registry::StripeWebhook::post_connect( $t, {
        type => 'payment_intent.succeeded', account => $acct, data => { object => $intent } } )->status_is(200);
    drive();

    my $payment = Registry::DAO::Payment->find( $sdb, { id => $payment_id } );
    is $payment->status, 'completed', 'the webhook completes the payment';
    is $payment->platform_offer_version_id, $solo->{id}, "stamped with sacp's Solo version";
    is $payment->platform_fee_cents, 225, 'and the fee Stripe took';
    my ($e) = Registry::DAO::Entitlement->created_by_payment( $sdb, $payment_id );
    ok $e, 'the booker\'s entitlement exists' or return;
    is $e->holder_user_id, $u->id, 'held by the booker';
    is $e->offer_version_id, $version->id, "stamped with sacp's offer version";
    is $e->payment_id, $payment_id, 'and linked to the payment carrying the Solo version';
    is_deeply $e->units( $sdb, $occurrence->id ), [ 1, 2 ], 'holding its two seats';
};

done_testing;
