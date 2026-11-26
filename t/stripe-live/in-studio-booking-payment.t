# ABOUTME: Gated real-Stripe proof that an in-studio booking is a direct charge on the studio's connected account.
# ABOUTME: The intent carries Solo's 2.5% application fee and no transfer_data, retries make one intent, and paying books it.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::StripeConnect;
use Test::Registry::StripeConfirm;
use Test::Registry::DB;
use Test::Registry::Helpers qw( import_all_workflows );
use Test::Registry::PricingProbe qw( give_tenant_terms );
use Test::Registry::Offers qw( offer_terms );
use Test::Registry::Async qw( settle );

use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::Payment;
use Registry::DAO::Project;
use Registry::DAO::Offer;
use Registry::DAO::Resource;
use Registry::DAO::Entitlement;
use Registry::DAO::WorkflowRun;
use Registry::PriceOps::PlatformTerms qw( platform_terms_for_tenant );
use Registry::Utility::WorkflowProcessor;
use Registry::Terms;

plan skip_all => 'STRIPE_SECRET_KEY (sk_test_) not set'
    unless Test::Registry::StripeConnect::available();

# DO NOT localise STRIPE_SECRET_KEY: the real test key must reach the payment step.

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
import_all_workflows($dao);

my $slug  = "isbp_live_$$";
my $admin = Registry::DAO::User->create( $db, {
    username => "isbp_live_admin_$$", email => "isbp_live_admin_$$\@test.example",
    name => 'ISBP Live Admin', user_type => 'admin' } );
Registry::DAO::Tenant->provision( $db, { name => "ISBP Live $$", slug => $slug, users => [$admin] } );
my $tdao = Registry::DAO->new( url => $test_db->uri, schema => $slug );
import_all_workflows($tdao);
my $tdb = $tdao->db;

note 'Waiting for charges_enabled on ready Stripe test account (up to 180s)...';
my $acct = Test::Registry::StripeConnect::ready_account();
like $acct, qr/^acct_/, 'ready account id obtained';
$db->query(
    'UPDATE registry.tenants SET stripe_connect_account_id = $1, stripe_charges_enabled = TRUE,
            stripe_details_submitted = TRUE WHERE slug = $2', $acct, $slug );
give_tenant_terms( $db, $slug, { rate => '0.025' } );

# A class with one occurrence a week out, and a $45 one-seat offer under SACP's policies.
my $room = $tdb->insert( 'locations', { name => 'Live room', slug => 'live-room', time_zone => 'America/New_York' },
    { returning => 'id' } )->hash->{id};
my %user = map {
    $_ => Registry::DAO::User->create( $tdb, {
        username => "isbp_live_${_}_$$", email => "isbp_live_${_}_$$\@test.example",
        name => "ISBP Live \u$_", user_type => $_ eq 'teacher' ? 'staff' : 'parent' } )
} qw( booker teacher );
my $class = Registry::DAO::Project->create( $tdb,
    { name => 'Live throwing', seats_per_occurrence => 6, metadata => { location_id => $room } } );
my $event = $tdb->query( q{
    INSERT INTO events (project_id, location_id, teacher_id, time, duration, capacity, status)
    VALUES (?, ?, ?, now() + interval '7 days', 90, 6, 'published') RETURNING id
}, $class->id, $room, $user{teacher}->id )->array->[0];
my $occurrence = Registry::DAO::Resource->for_occurrence( $tdb, $event );
my $version    = Registry::DAO::Offer->create( $tdb, { name => 'One seat' } )
    ->draft( $tdb, offer_terms( undef, class_project_id => $class->id, price_cents => 4500, per_booking_cap => 4,
        policies => {
            refund => { kind => 'none' },
            change => { kind => 'window', window_hours => 48, fee_cents => 1000, targets => 'same_offer' },
            use    => { kind => 'optional_attendance' },
            expiry => { kind => 'end_of_occurrence' },
        } ) )
    ->publish($tdb);

my $workflow = $tdao->find( Workflow => { slug => 'in-studio-booking' } );
sub step ($slug) { $workflow->get_step( $tdb, { slug => $slug } ) }

# A run that chose $count seats, agreed to the terms, signed in and holds them.
sub held ($count) {
    my $u   = $user{booker};
    my $run = Registry::WorkflowProcessor->new( dao => $tdao )->new_run( $workflow,
        { user => { id => $u->id, name => $u->name }, user_id => $u->id, __tenant_slug => $slug } );
    for (
        [ occurrence => { occurrence_id => $occurrence->id } ],
        [ offer      => { offer_version_id => $version->id, count => $count,
                          agree_to_terms => 1, terms_version_shown => Registry::Terms::VERSION } ],
        [ account    => { action => 'continue_logged_in' } ],
        [ hold       => {} ],
    ) {
        my $r = $run->process( $tdb, step( $_->[0] ), $_->[1] );
        die "$_->[0] refused: @{ $r->{errors} }" if ref $r eq 'HASH' && $r->{errors};
    }
    return Registry::DAO::WorkflowRun->find( $tdb, { id => $run->id } );
}

sub payment_of ($run) {
    my $id = Registry::DAO::WorkflowRun->find( $tdb, { id => $run->id } )->data->{owed_payment_id};
    return Registry::DAO::Payment->find( $tdb, { id => $id } );
}

subtest 'booking is a direct charge on the studio account with the solo fee' => sub {
    my $run   = held(2);
    my $first = settle( $run->process( $tdb, step('payment'), {} ) );
    ok $first->{stay}, 'the payment step waits for the card';
    is $first->{template_data}{step_data}{stripe_account}, $acct, "on the studio's account";

    my $intent_id = payment_of($run)->stripe_payment_intent_id;
    like $intent_id, qr/^pi_/, 'a real intent was created';
    my $intent = Test::Registry::StripeConfirm::_get( "/payment_intents/$intent_id", $acct );
    is $intent->{id}, $intent_id, 'it is found on the studio account, retrieved with its Stripe-Account';
    is $intent->{amount}, 9000, 'for 2 x the price';
    is $intent->{application_fee_amount}, Registry::DAO::Payment::application_fee_cents( 9000, '0.025' ),
        'with application_fee_amount 2.5% of the amount';
    is $intent->{application_fee_amount}, 225, 'which is 225 cents';
    ok !$intent->{transfer_data}, 'and no transfer_data';
    ok !$intent->{on_behalf_of}, 'nor on_behalf_of';

    is Test::Registry::StripeConfirm::confirm( $intent_id, undef, $acct )->{status}, 'succeeded',
        'Stripe takes the payment on the studio account';
    settle( $run->process( $tdb, step('payment'), { payment_intent_id => $intent_id } ) );
    is payment_of($run)->status, 'completed', 'the return completes the payment';
    is payment_of($run)->platform_offer_version_id, platform_terms_for_tenant( $db, $slug )->{id},
        "stamped with the studio's platform offer version";
    is payment_of($run)->platform_fee_cents, 225, 'and the fee Stripe took';

    $run->process( $tdb, step('complete'), {} );
    my ($e) = Registry::DAO::Entitlement->created_by_payment( $tdb, payment_of($run)->id );
    ok $e, 'the booking is made' or return;
    is $e->holder_user_id, $user{booker}->id, 'held by the booker';
    is_deeply $e->units( $tdb, $occurrence->id ), [ 1, 2 ], 'holding its two seats';
};

subtest 'retried payment step creates one payment intent' => sub {
    my $run = held(1);
    settle( $run->process( $tdb, step('payment'), {} ) ) for 1 .. 3;    # Minion retries up to three times
    my $intent_id = payment_of($run)->stripe_payment_intent_id;
    like $intent_id, qr/^pi_/, 'an intent was created';
    is $tdb->query( q{SELECT count(*) FROM payments WHERE metadata->>'workflow_run_id' = ?}, $run->id )->array->[0], 1,
        'the run has one payment';
    my $payment_id = payment_of($run)->id;
    my $listed = Test::Registry::StripeConfirm::_get( '/payment_intents?limit=100', $acct )->{data};
    is scalar( grep { ( $_->{metadata}{payment_id} // '' ) eq $payment_id } @$listed ), 1,
        'and the studio account holds one intent for it';
};

done_testing;
