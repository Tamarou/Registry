#!/usr/bin/env perl
# ABOUTME: The summer-camp payment page says what will happen, never "demo": a $0 cart completes plainly,
# ABOUTME: a priced cart with no Stripe key and a cart that cannot be priced show their refusal and no submit.
use 5.42.0;
use warnings;
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Registry;
use Test::Registry::DB;
use Test::Registry::Helpers qw(authenticate_as);
use Registry::DAO qw(Workflow);
use Registry::DAO::WorkflowRun;
use Registry::DAO::Session;
use Registry::DAO::PricingPlan;
use Registry::DAO::WorkflowSteps::Payment;
use Mojo::Home;
use YAML::XS qw(Load);

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
$ENV{DB_URL} = $test_db->uri;

for my $file ( Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each ) {
    next if Load( $file->slurp )->{draft};
    Workflow->from_yaml( $dao, $file->slurp );
}

my $t = Test::Registry::Mojo->new('Registry');

# The parent whose cart it is: a run answers only to its own user.
my $parent = $dao->create( User => { username => 'no_key_parent', name => 'No Key Parent',
    email => 'no_key_parent@example.com', user_type => 'parent' } );
authenticate_as( $t, $parent );

my $workflow     = $dao->find( Workflow => { slug => 'summer-camp-registration' } );
my $payment_step = Registry::DAO::WorkflowStep->find( $db, { workflow_id => $workflow->id, slug => 'payment' } );

# A session priced at $cents, or with no plan at all when $cents is undef.
sub session_at ($cents) {
    my $session = Registry::DAO::Session->create( $db, {
        name => 'Week at ' . ( $cents // 'no price' ), start_date => '2099-07-02', end_date => '2099-07-09',
        status => 'published' } );
    Registry::DAO::PricingPlan->create( $db, {
        session_id => $session->id, plan_name => "At $cents", plan_type => 'standard', amount_cents => $cents } )
        if defined $cents;
    return $session;
}

# A run parked on the payment step whose cart is one child in $session.
my $kids = 0;
sub page_for ($session) {
    my $child = 'c0ffee00-0000-4000-8000-' . sprintf '%012d', ++$kids;
    my $run   = $workflow->new_run($db);
    $db->update( 'workflow_runs', { latest_step_id => $payment_step->id }, { id => $run->id } );
    $run->update_data( $db, {
        user_id            => $parent->id,
        children           => [ { id => $child, first_name => 'Kid', last_name => '' } ],
        session_selections => { $child => $session->id },
        enrollment_items   => [ { child_id => $child, session_id => $session->id } ],
    } );
    return $t->get_ok( "/summer-camp-registration/@{[ $run->id ]}/payment" )->status_is(200);
}

delete local $ENV{STRIPE_SECRET_KEY};

subtest 'a $0 cart with no key offers a plain completion' => sub {
    page_for( session_at(0) )
        ->content_unlike( qr/demo/i, 'no demo wording' )
        ->content_like( qr/Complete Registration\s*</, 'the button says Complete Registration' )
        ->element_exists( 'form button[type="submit"]', 'and can be submitted' );
};

subtest 'a priced cart with no key shows the refusal' => sub {
    my $refusal = Registry::DAO::WorkflowSteps::Payment->payment_unavailable_message;
    page_for( session_at(15000) )
        ->content_unlike( qr/demo/i, 'no demo wording' )
        ->content_like( qr/\Q$refusal\E/, 'the refusal is shown' )
        ->element_exists_not( 'button[type="submit"]', 'with nothing to submit' )
        ->content_unlike( qr/Proceed to Payment/, 'and no offer to pay' );
};

subtest 'a cart that cannot be priced shows its refusal' => sub {
    # Even with a key: the refusal is about the price, not Stripe.
    local $ENV{STRIPE_SECRET_KEY} = 'sk_test_placeholder';
    my $refusal = Registry::DAO::WorkflowSteps::Payment->unpriced_cart_refusal( {}, [] );
    page_for( session_at(undef) )
        ->content_like( qr/\Q$refusal\E/, 'the refusal is shown' )
        ->content_unlike( qr/No payment is needed/, 'not that it is free' )
        ->element_exists_not( 'button[type="submit"]', 'with nothing to submit' );
};

done_testing;
