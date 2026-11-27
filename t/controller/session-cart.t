#!/usr/bin/env perl
# ABOUTME: The session-checkout cart over HTTP: each chosen child, a session, a price the child qualifies for and a plan.
# ABOUTME: Sibling prices count earlier lines, early-bird is preselected when cheapest, and the terms are agreed here.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use List::Util qw( uniq );
use Mojo::File qw( path );
use POSIX qw( strftime );
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( authenticate_as import_all_workflows days_from_now );
use Test::Registry::Offers qw( instalment_plan );
use Test::Registry::Sessions qw( make_session session_offer );
use Registry::DAO::Family;
use Registry::DAO::WorkflowRun;
use Registry::Terms;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
$ENV{DB_URL} = $test_db->uri;
import_all_workflows($dao);

# Early-bird ends a month from the run, so it is on sale whenever the suite runs.
my $EARLY_ENDS = strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime( time + 30 * 86_400 ) );

my $made = 0;

# A parent and its children, eldest first: ($parent, @kids).
sub family (@names) {
    my $n      = ++$made;
    my $parent = Test::Registry::Fixtures::create_user( $dao,
        { username => "cart_parent_$n", name => "Cart Parent $n", email => "cart$n\@cart.test", user_type => 'parent' } );
    my $born = 2014;
    return ( $parent, map {
        Registry::DAO::Family->add_child( $db, $parent->id, {
            child_name => "$_ $n", birth_date => ( $born += 2 ) . '-05-01', grade => '3',
            medical_info => {}, emergency_contact => { name => 'EC', phone => '555' } } )
    } @names );
}

# A session two months out sold at regular $300, sibling $270 and early-bird $250.
sub priced_session (%session) {
    my $s = make_session( $db, days => [ map { days_from_now($_) } 60 .. 62 ], %session );
    my ( $regular, $sibling, $early ) = map { session_offer( $db, $s, %$_ ) }
        { price_cents => 30000 },
        { price_cents => 27000, conditions => [ { kind => 'family_holds_entitlement' } ] },
        { price_cents => 25000, conditions => [ { kind => 'before', at => $EARLY_ENDS } ] };
    return { session => $s, regular => $regular, sibling => $sibling, early => $early };
}

my $css = join '', map { path( 'public/css', $_ )->slurp } qw( theme.css app.css );

sub check_screen ( $t, $screen ) {
    my @classes = uniq map { split ' ', $_->attr('class') } $t->tx->res->dom->find('#workflow-content [class]')->each;
    is_deeply [ grep { $css !~ /\.\Q$_\E(?![\w-])/ } @classes ], [], "$screen uses design-system classes only";
}

# $parent's signed-in client at the cart with @kids chosen; returns the client
# and the cart's URL.
sub at_cart ( $parent, @kids ) {
    my $t = Test::Registry::Mojo->new('Registry');
    authenticate_as( $t, $parent );
    $t->get_ok('/session-checkout')->status_is(200);
    check_screen( $t, 'account' );
    $t->post_ok( $t->tx->res->dom->at('#workflow-content form')->attr('action') => form => { action => 'continue_logged_in' } )
        ->status_is(302);
    like my $children = $t->tx->res->headers->location, qr{/children\z}, 'on to choosing children';
    $t->get_ok($children)->status_is(200);
    check_screen( $t, 'children' );
    $t->element_exists( qq{#workflow-content input[type="checkbox"][name="child_${\ $_->id }"]}, 'each child can be chosen' )
        for @kids;
    $t->post_ok( $t->tx->res->dom->at('#workflow-content form')->attr('action') =>
        form => { action => 'continue', map { ( 'child_' . $_->id => 1 ) } @kids } )->status_is(302);
    like my $cart = $t->tx->res->headers->location, qr{/cart\z}, 'on to the cart';
    $t->get_ok($cart)->status_is(200);
    check_screen( $t, 'cart' );
    return ( $t, $cart );
}

# The form adding a line for $kid in session $s on the page $t shows.
sub line_form ( $t, $kid, $s ) {
    return $t->tx->res->dom->at( sprintf '#workflow-content form#line-%s-%s', $kid->id, $s->id );
}

# The version and plan pairs $form offers, and the one checked.
sub choices ($form) { [ map { $_->attr('value') } $form->find('input[name="choice"]')->each ] }
sub checked ($form) { my $c = $form->at('input[name="choice"][checked]'); $c && $c->attr('value') }

# Posts a line to the cart at $cart; returns the run's cart lines after it.
sub add_line ( $t, $cart, $kid, $s, $version, $plan = 'pay' ) {
    $t->post_ok( $cart => form => { action => 'add_line', family_member_id => $kid->id, resource_id => $s->id,
        choice => $version->id . "/$plan" } );
    return run_of($cart)->data->{cart_lines} // [];
}

sub run_of ($url) {
    my ($id) = $url =~ m{/session-checkout/([^/]+)/} or die "no run in $url";
    return Registry::DAO::WorkflowRun->find( $db, { id => $id } );
}

subtest 'child one sees early bird preselected and no sibling price' => sub {
    my ( $p1, $p2 ) = ( priced_session(), priced_session() );
    my ( $parent, $kid1, $kid2 ) = family( 'Ada', 'Ben' );
    my ( $t, $cart ) = at_cart( $parent, $kid1, $kid2 );
    $t->content_like( qr/Prices you qualify for/, 'the prices are the ones the child qualifies for' )
        ->content_like( qr/Ada \d+/, 'the first child is named' )->content_like( qr/Ben \d+/, 'and the second' );

    my $form = line_form( $t, $kid1, $p1->{session} ) or return fail 'no line form for child one';
    is checked($form), $p1->{early}->id . '/pay', 'early bird, the cheapest, is preselected';
    is_deeply choices($form), [ $p1->{early}->id . '/pay', $p1->{regular}->id . '/pay' ],
        'early bird then regular; no sibling price before any sibling holds a place';
    like $form->all_text, qr/\$250\.00/, 'with its price';
    like $form->all_text, qr/Sales are final\./, 'and its policies in plain words';
    $t->element_exists( '#workflow-content a[href="/terms"]', 'the page links /terms' );
};

subtest 'child two sees the sibling price after child one line' => sub {
    my ( $p1, $p2 ) = ( priced_session(), priced_session() );
    my ( $parent, $kid1, $kid2 ) = family( 'Cal', 'Dee' );
    my ( $t, $cart ) = at_cart( $parent, $kid1, $kid2 );
    ok !( grep { $_ eq $p2->{sibling}->id . '/pay' } choices( line_form( $t, $kid2, $p2->{session} ) )->@* ),
        'no sibling price for child two before child one has a line';

    my $lines = add_line( $t, $cart, $kid1, $p1->{session}, $p1->{regular} );
    $t->status_is(200);
    is_deeply $lines, [ { family_member_id => $kid1->id, resource_id => $p1->{session}->id,
        offer_version_id => $p1->{regular}->id, payment_plan_id => 'pay' } ], 'child one has a line';
    $t->content_like( qr/Cal \d+.*Session \d+.*\$300\.00/s, 'the cart shows it' );

    my $form = line_form( $t, $kid2, $p2->{session} ) or return fail 'no line form for child two';
    is_deeply choices($form), [ map { $p2->{$_}->id . '/pay' } qw( early sibling regular ) ],
        'child two may choose the sibling price, after child one\'s line';
    is checked($form), $p2->{early}->id . '/pay', 'the cheapest is still preselected';
    ok !( grep { $_ eq $p2->{sibling}->id . '/pay' } choices( line_form( $t, $kid1, $p2->{session} ) )->@* ),
        'child one\'s own line does not give child one the sibling price';

    $lines = add_line( $t, $cart, $kid2, $p2->{session}, $p2->{sibling} );
    is_deeply [ map { $_->{offer_version_id} } @$lines ], [ $p1->{regular}->id, $p2->{sibling}->id ],
        'child two takes the sibling price, in the order shown';
};

subtest 'a full session shows join the waitlist' => sub {
    my $p = priced_session( capacity => 0 );
    my ( $parent, $kid ) = family('Eve');
    my ( $t, $cart ) = at_cart( $parent, $kid );
    ok !line_form( $t, $kid, $p->{session} ), 'a full session takes no line';
    $t->content_like( qr/Join the waitlist/, 'it offers the waitlist instead' );
};

# The refusal page a posted line or checkout was redirected to.
sub refused_with ( $t, $cart, $why ) {
    $t->status_is(302);
    is $t->tx->res->headers->location, $cart, 'back to the cart';
    $t->get_ok($cart)->status_is(200)->content_like( $why, 'the refusal is shown' );
}

subtest 'the sibling price for child one is refused' => sub {
    my $p = priced_session();
    my ( $parent, $kid1, $kid2 ) = family( 'Fay', 'Gus' );
    my ( $t, $cart ) = at_cart( $parent, $kid1, $kid2 );
    is_deeply add_line( $t, $cart, $kid1, $p->{session}, $p->{sibling} ), [], 'no line is stored';
    refused_with( $t, $cart, qr/Choose one of the listed prices/ );
};

subtest 'a child from another family is refused' => sub {
    my $p = priced_session();
    my ( $parent, $kid ) = family('Hal');
    my ( undef, $stranger ) = family('Ivy');
    my ( $t, $cart ) = at_cart( $parent, $kid );
    ok !line_form( $t, $stranger, $p->{session} ), 'another family\'s child is not shown';
    is_deeply add_line( $t, $cart, $stranger, $p->{session}, $p->{regular} ), [], 'no line is stored for them';
    refused_with( $t, $cart, qr/Choose one of your own children/ );

    # Chosen at the children step by a planted id, still not in the cart.
    my $run = run_of($cart);
    $run->update_data( $db, { selected_child_ids => [ $kid->id, $stranger->id ] } );
    $t->get_ok($cart)->status_is(200);
    ok !line_form( $t, $stranger, $p->{session} ), 'nor when the run names them';
    is_deeply add_line( $t, $cart, $stranger, $p->{session}, $p->{regular} ), [], 'nor is a line stored';
};

subtest 'no terms agreement keeps the cart step' => sub {
    my $p = priced_session();
    my ( $parent, $kid ) = family('Jo');
    my ( $t, $cart ) = at_cart( $parent, $kid );
    add_line( $t, $cart, $kid, $p->{session}, $p->{early} );
    $t->post_ok( $cart => form => { action => 'checkout', terms_version_shown => Registry::Terms::VERSION } );
    refused_with( $t, $cart, qr/Agree to the terms of service/ );
    my $run = run_of($cart);
    is $run->latest_step($db)->slug, 'children', 'the run has not left the cart';
    ok !exists $run->data->{agreed_terms_version}, 'and no agreement is recorded';

    $t->post_ok( $cart => form => { action => 'checkout', agree_to_terms => 1,
        terms_version_shown => Registry::Terms::VERSION } );
    $run = run_of($cart);
    is $run->latest_step($db)->slug, 'cart', 'agreeing moves the run past the cart';
    is $run->data->{agreed_terms_version}, Registry::Terms::VERSION, 'recording the version agreed';
};

subtest 'a weekly plan past the session end is not listed' => sub {
    # Three days starting in ten days: a fourth weekly payment, three weeks
    # out, falls after the last day; a second, one week out, does not.
    my $s = make_session( $db, days => [ map { days_from_now($_) } 10 .. 12 ] );
    my $version = session_offer( $db, $s, price_cents => 30000,
        payment_plans => [ { id => 'pay', kind => 'one_time' },
            instalment_plan( id => 'four', count => 4, cadence => 'weekly' ),
            instalment_plan( id => 'two',  count => 2, cadence => 'weekly' ) ],
        policies => { refund => { kind => 'none' }, missed_payment => { kind => 'end' } } );
    my ( $parent, $kid ) = family('Kit');
    my ( $t, $cart ) = at_cart( $parent, $kid );
    my $form = line_form( $t, $kid, $s ) or return fail 'no line form';
    is_deeply choices($form), [ map { $version->id . "/$_" } qw( pay two ) ], 'the plan past the end is not offered';
    like $form->all_text, qr/Pay in 2 weekly payments of \$150\.00/, 'a plan that fits says what it costs';
    like $form->all_text, qr/Not offered: the last payment would fall after the session ends/, 'the other says why it is not offered';

    is_deeply add_line( $t, $cart, $kid, $s, $version, 'four' ), [], 'posting it anyway stores no line';
    refused_with( $t, $cart, qr/Not offered: the last payment would fall after the session ends/ );
};

done_testing;
