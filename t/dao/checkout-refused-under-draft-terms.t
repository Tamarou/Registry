# ABOUTME: While /terms is the DRAFT placeholder, no payment intent is created in any mode but development and test.
# ABOUTME: ADR 005 ruling 12: production checkout is refused until perigrin's terms replace the placeholder.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::PricingProbe qw( state_platform_terms );
use Registry::DAO::Payment;
use Registry::Terms;

my $t   = Test::Registry::DB->new;
my $dao = $t->db;
my $db  = $dao->db;

$db->query( q{INSERT INTO registry.tenants (name, slug, stripe_connect_account_id)
              VALUES ('Draft Terms Studio', 'draft_terms', 'acct_draft_terms')} );
state_platform_terms( $db, 'draft_terms', { rate => 0 } );

my $user = $dao->create( User => {
    username  => 'draft_terms_payer',
    email     => 'payer@draft-terms.test',
    name      => 'Draft Terms Payer',
    user_type => 'parent',
} );

my $REFUSED = qr/\ACheckout is closed until the terms of service are final/;

sub new_payment () {
    Registry::DAO::Payment->create( $db, {
        user_id      => $user->id,
        amount_cents => 2500,
        metadata     => { tenant_slug => 'draft_terms' },
    } );
}

ok Registry::Terms::is_placeholder(), 'the terms in force are the DRAFT placeholder';

subtest 'which modes refuse checkout' => sub {
    for my $mode (qw( production staging )) {
        like Registry::Terms::checkout_refusal($mode), qr/terms/i, "$mode refuses";
    }
    for my $mode (qw( development test )) {
        is Registry::Terms::checkout_refusal($mode), undef, "$mode does not";
    }
    local $ENV{MOJO_MODE};
    local $ENV{PLACK_ENV};
    is Registry::Terms::checkout_refusal(), undef, 'no mode set is development, as Mojolicious reads it';
};

for my $mode (qw( production staging )) {
    local $ENV{MOJO_MODE} = $mode;

    subtest "$mode checkout refused before stripe" => sub {
        my $payment = new_payment();
        my $error;
        $payment->create_payment_intent_async( $db, { description => 'Class' } )
          ->catch( sub ($e) { $error = $e } )->wait;
        like $error, $REFUSED, 'the async intent is refused, naming the terms';

        ok !eval { $payment->create_payment_intent( $db, { description => 'Class' } ); 1 },
          'the blocking intent is refused too';
        like $@, $REFUSED, '... naming the terms';

        my $row = Registry::DAO::Payment->find( $db, { id => $payment->id } );
        is $row->stripe_payment_intent_id, undef, 'no intent was recorded';
        is $row->status, 'pending', 'the row is left as it was';
    };
}

done_testing;
