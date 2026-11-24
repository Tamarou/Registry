#!/usr/bin/env perl
# ABOUTME: The offer-publishing screens over HTTP: an admin walks them to the complete page.
# ABOUTME: Design-system classes only, no body swaps, escaped offer names, and no way in for staff or anonymous visitors.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use List::Util qw( uniq );
use Mojo::File qw( path );
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( authenticate_as import_all_workflows join_tenant );
use Registry;
use Registry::DAO;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
$ENV{DB_URL} = $test_db->uri;
import_all_workflows($dao);

my $admin = Test::Registry::Fixtures::create_user( $dao,
    { username => 'offer_admin', name => 'Offer Admin', email => 'admin@offers.test', user_type => 'admin' } );
join_tenant( $dao, $admin, 'admin' );
my $staff = Test::Registry::Fixtures::create_user( $dao,
    { username => 'offer_staff', name => 'Offer Staff', email => 'staff@offers.test', user_type => 'staff' } );
join_tenant( $dao, $staff, 'staff' );

my $seats = Test::Registry::Fixtures::create_resource( $db,
    { name => 'Studio seats', kind => 'finite', capacity => 12 } );

# A client with its own session, signed in as $user (none for anonymous), so
# each subtest starts its own run.
sub client ( $user = undef ) {
    my $t = Test::Registry::Mojo->new('Registry');
    authenticate_as( $t, $user ) if $user;
    return $t;
}

# Every class a design-system template may use is defined in our CSS; a
# Tailwind-style utility is not, and renders as nothing.
my $css = join '', map { path( 'public/css', $_ )->slurp } qw( theme.css app.css );

sub check_screen ( $t, $screen ) {
    my $dom     = $t->tx->res->dom;
    my @classes = uniq map { split ' ', $_->attr('class') } $dom->find('#workflow-content [class]')->each;
    is_deeply [ grep { $css !~ /\.\Q$_\E(?![\w-])/ } @classes ], [],
        "$screen uses design-system classes only";
    unlike $t->tx->res->body, qr/hx-target\s*=\s*["']body/, "$screen does not swap the body";
}

# Submits the page's form with %fields, each of which the form must offer,
# and follows the redirect to the next screen. Returns its URL.
sub submit_step ( $t, $screen, %fields ) {
    my $form = $t->tx->res->dom->at('#workflow-content form');
    ok $form, "$screen has a form" or return;
    ok $form->at(qq{[name="$_"]}), "$screen asks for $_" for sort keys %fields;
    $t->post_ok( $form->attr('action') => form => \%fields )->status_is(302);
    my $next = $t->tx->res->headers->location;
    $t->get_ok($next)->status_is(200);
    return $next;
}

my %BASICS = ( resource_id => $seats->id, offer_name => 'Life drawing' );
my %PRICE  = ( price_cents => 4000, currency => 'USD', units_per_acceptance => 1, per_booking_cap => 2 );

subtest 'admin completes offer publishing over http' => sub {
    my $t = client($admin);
    $t->get_ok('/offer-publishing')->status_is(200);
    check_screen( $t, 'resource' );
    like submit_step( $t, 'resource', resource_mode => 'existing' ), qr{/offer-basics\z}, 'on to the offer';
    $t->content_like(qr/Studio seats/);
    check_screen( $t, 'offer-basics' );

    like submit_step( $t, 'offer-basics', %BASICS ), qr{/offer-price\z}, 'on to the price';
    check_screen( $t, 'offer-price' );
    like submit_step( $t, 'offer-price', %PRICE ), qr{/one-time-payment\z}, 'on to payment';
    check_screen( $t, 'one-time-payment' );
    like submit_step( $t, 'one-time-payment', one_time => 'offered' ), qr{/percentage-of-sales-payment\z},
        'on to the share of sales';
    check_screen( $t, 'percentage-of-sales-payment' );
    like submit_step( $t, 'percentage-of-sales-payment', percentage_of_sales => 'declined' ), qr{/refund-policy\z},
        'on to refunds';
    check_screen( $t, 'refund-policy' );
    like submit_step( $t, 'refund-policy', refund => 'none' ), qr{/change-policy\z}, 'on to changes';
    check_screen( $t, 'change-policy' );
    like submit_step( $t, 'change-policy', change => 'none' ), qr{/use-policy\z}, 'on to use';
    check_screen( $t, 'use-policy' );
    like submit_step( $t, 'use-policy', use => 'optional_attendance' ), qr{/expiry-policy\z}, 'on to expiry';
    check_screen( $t, 'expiry-policy' );
    like submit_step( $t, 'expiry-policy', expiry => 'never' ), qr{/publish\z}, 'on to publish';
    check_screen( $t, 'publish' );
    $t->content_like(qr/Life drawing/)->content_like(qr/\$40/);
    my %reviewed = map { $_->text => $_->next->all_text } $t->tx->res->dom->find('#workflow-content dt')->each;
    is_deeply [ @reviewed{ 'Refund policy', 'Change policy', 'Use policy', 'Expiry policy' } ],
        [ 'None', 'None', 'Optional attendance', 'Never' ], 'the review shows every chosen policy by name before publishing';

    like submit_step( $t, 'publish', action => 'publish' ), qr{/complete\z},
        'publishing lands on the complete page';
    check_screen( $t, 'complete' );
    $t->content_like(qr/Life drawing/);

    my $published = $db->query( q{
        SELECT count(*) FROM offer_versions v JOIN offers o ON o.id = v.offer_id
         WHERE o.name = 'Life drawing' AND v.resource_id = ? AND v.published_at IS NOT NULL
    }, $seats->id )->array->[0];
    is $published, 1, 'one offer version is published for the resource';
};

subtest 'the review shows the percentage plan, policy names and the change fee in plain words' => sub {
    my $class = $db->insert( 'projects', { name => 'Figure class', slug => 'figure-class' }, { returning => 'id' } )->hash->{id};
    my $t = client($admin);
    $t->get_ok('/offer-publishing')->status_is(200);
    submit_step( $t, 'resource', resource_mode => 'class', class_project_id => $class );
    submit_step( $t, 'offer-basics', offer_name => 'Figure nights' );
    submit_step( $t, 'offer-price', %PRICE );
    submit_step( $t, 'one-time-payment', one_time => 'declined' );
    submit_step( $t, 'percentage-of-sales-payment', percentage_of_sales => 'offered', rate_percent => '2.5' );
    submit_step( $t, 'refund-policy', refund => 'keep_fee_with_admin_exception' );
    submit_step( $t, 'change-policy', change => 'window', window_hours => 24, fee_cents => 1550, targets => 'same_offer' );
    submit_step( $t, 'use-policy', use => 'none' );
    like submit_step( $t, 'expiry-policy', expiry => 'end_of_occurrence' ), qr{/publish\z}, 'on to the review';
    check_screen( $t, 'publish' );
    my %reviewed = map { $_->text => $_->next->all_text } $t->tx->res->dom->find('#workflow-content dt')->each;
    is_deeply {
        %reviewed{ 'One-time payment', 'Percentage of sales', 'Refund policy', 'Change policy', 'Use policy', 'Expiry policy' }
    }, {
        'One-time payment'    => 'Not offered',
        'Percentage of sales' => 'Offered, at 2.5% of each sale',
        'Refund policy'       => 'Keep the fee, unless an administrator makes an exception',
        'Change policy'       => 'A change window, up to 24 hours before the start, for a fee of $15.50',
        'Use policy'          => 'None',
        'Expiry policy'       => 'At the end of the occurrence',
    }, 'every term in plain words';
};

subtest 'offer name is escaped' => sub {
    my $t    = client($admin);
    my $name = '<script>alert("offer")</script>';
    $t->get_ok('/offer-publishing')->status_is(200);
    submit_step( $t, 'resource', resource_mode => 'existing' );
    submit_step( $t, 'offer-basics', %BASICS, offer_name => $name );
    submit_step( $t, 'offer-price', %PRICE );
    submit_step( $t, 'one-time-payment', one_time => 'offered' );
    submit_step( $t, 'percentage-of-sales-payment', percentage_of_sales => 'declined' );
    submit_step( $t, 'refund-policy', refund => 'none' );
    submit_step( $t, 'change-policy', change => 'none' );
    submit_step( $t, 'use-policy', use => 'none' );
    submit_step( $t, 'expiry-policy', expiry => 'never' );
    $t->content_unlike(qr/<script>alert/)->content_like(qr/&lt;script&gt;alert/, 'escaped on the publish page');
    submit_step( $t, 'publish', action => 'publish' );
    $t->content_unlike(qr/<script>alert/)->content_like(qr/&lt;script&gt;alert/, 'and on the complete page');
};

subtest 'staff post to an admins offer run refused' => sub {
    my $t = client($admin);
    $t->get_ok('/offer-publishing')->status_is(200);
    submit_step( $t, 'resource', resource_mode => 'existing' );
    my $price_url = submit_step( $t, 'offer-basics', %BASICS );
    my ($run_id)  = $price_url =~ m{/offer-publishing/([^/]+)/offer-price};
    my $before    = $db->query( 'SELECT data, latest_step_id FROM workflow_runs WHERE id = ?', $run_id )->hash;

    my $s = client($staff);
    $s->get_ok('/offer-publishing')->status_is(403, 'staff are refused at the route');
    $s->post_ok( $price_url => form => \%PRICE )->status_is(403, 'and a POST to a later step of an admin\'s run');
    $s->content_unlike( qr/CSRF token validation failed/, 'refused for the role, not for a missing token' );
    is_deeply $db->query( 'SELECT data, latest_step_id FROM workflow_runs WHERE id = ?', $run_id )->hash,
        $before, 'the run is unchanged';
};

subtest 'anonymous request creates no offer run' => sub {
    my $runs = sub {
        $db->query( q{SELECT count(*) FROM workflow_runs r JOIN workflows w ON w.id = r.workflow_id
                       WHERE w.slug = 'offer-publishing'} )->array->[0];
    };
    my $before = $runs->();
    my $t      = client();
    $t->get_ok('/offer-publishing')->status_is(302)->header_is( Location => '/auth/login',
        'an anonymous GET is sent to log in' );
    $t->post_ok( '/offer-publishing' => form => {} )->status_is(302)->header_is( Location => '/auth/login',
        'and so is an anonymous POST' );
    is $runs->(), $before, 'and no run is created';
};

subtest 'every offer-publishing template starts with its ABOUTME header' => sub {
    for my $file ( path('templates/offer-publishing')->list->grep(qr/\.html\.ep\z/)->each ) {
        my @head = ( split /\n/, $file->slurp, 3 )[ 0, 1 ];
        is scalar( grep { /\A%# ABOUTME: \S/ } @head ), 2, $file->basename . ' starts with two %# ABOUTME: lines';
    }
};

done_testing;
