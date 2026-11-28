#!/usr/bin/env perl
# ABOUTME: The session cart's payment page says what will happen, never "demo": it offers to pay what is due,
# ABOUTME: and a charge refused for want of a Stripe key shows its refusal, no card form, and a way to start again.
use 5.42.0;
use warnings;
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }
use lib qw(lib t/lib);
use Test::More;
use List::Util qw( uniq );
use Mojo::File qw( path );
use Test::Registry::Mojo;
use Registry;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( authenticate_as import_all_workflows days_from_now );
use Test::Registry::PricingProbe qw( state_platform_terms );
use Test::Registry::Sessions qw( make_session session_offer held_cart );
use Registry::DAO::FamilyMember;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
$ENV{DB_URL} = $test_db->uri;
import_all_workflows($dao);

my $seller = Test::Registry::Fixtures::platform_seller($db);
$db->query( q{UPDATE registry.tenants SET stripe_charges_enabled = TRUE, stripe_details_submitted = TRUE
               WHERE slug = ?}, $seller );
state_platform_terms( $db, $seller, { rate => 0 } );

my $t = Test::Registry::Mojo->new('Registry');

# The parent whose cart it is: a run answers only to its own user.
my $parent = Test::Registry::Fixtures::create_user( $dao, { username => 'no_key_parent', name => 'No Key Parent',
    email => 'no_key_parent@example.com', user_type => 'parent' } );
authenticate_as( $t, $parent );
my $kid = Registry::DAO::FamilyMember->create( $db, { family_id => $parent->id, child_name => 'Kid', birth_date => '2016-01-01' } );

my $css = join '', map { path( 'public/css', $_ )->slurp } qw( theme.css app.css );
sub design_system_only ($screen) {
    my @classes = uniq map { split ' ', $_->attr('class') } $t->tx->res->dom->find('#workflow-content [class]')->each;
    is_deeply [ grep { $css !~ /\.\Q$_\E(?![\w-])/ } @classes ], [], "$screen uses design-system classes only";
}

# A run parked on the payment step whose cart is the child in a $150 session.
sub payment_url () {
    my $s = make_session( $db, days => [ map { days_from_now($_) } 30 .. 32 ] );
    my ($run) = held_cart( $dao, $parent->id, [ $kid->id, $s->id, session_offer( $db, $s, price_cents => 15000 )->id, 'pay' ] );
    return "/session-checkout/@{[ $run->id ]}/payment";
}

delete local $ENV{STRIPE_SECRET_KEY};

subtest 'the page offers to pay what is due' => sub {
    $t->get_ok( payment_url() )->status_is(200)
        ->content_unlike( qr/demo/i, 'no demo wording' )
        ->content_like( qr/Due today: \$150\.00/, 'the amount due is shown' )
        ->element_exists( 'form button[type="submit"]', 'and can be paid' );
    design_system_only('payment');
};

subtest 'a priced cart with no key shows the refusal' => sub {
    $t->ua->max_redirects(1);
    my @warned;
    local $SIG{__WARN__} = sub { push @warned, @_ };
    $t->post_ok( payment_url() )->status_is(200)
        ->content_unlike( qr/demo/i, 'no demo wording' )
        ->content_like( qr/This payment cannot be taken right now\. Nothing has been charged\./, 'the refusal is shown' )
        ->element_exists_not( '#payment-form', 'with no card form' )
        ->content_like( qr/Start a new checkout/, 'and a way to start again' );
    like "@warned", qr/STRIPE_SECRET_KEY is not set/, 'the refusal is logged';
    design_system_only('payment refusal');
};

done_testing;
