#!/usr/bin/env perl
# ABOUTME: Morgan can see what families still owe, and that a failed instalment did not unenroll anyone.
# ABOUTME: keep_and_flag is only a policy if the flag is somewhere she looks.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use experimental qw(defer signatures);
use Test::More import => [qw( done_testing is ok like unlike subtest )];
defer { done_testing };

use Test::Registry::DB;
use Test::Registry::Mojo;
use Test::Registry::Helpers qw(authenticate_as);
use Registry::DAO::Payment;

my $t_db = Test::Registry::DB->new;
my $dao  = $t_db->db;
my $db   = $dao->db;
$ENV{DB_URL} = $t_db->uri;

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper( dao => sub { $dao } );

my $admin = $dao->create( User => { username => 'instal_admin', user_type => 'admin' } );
authenticate_as( $t, $admin );

my $parent = $dao->create( User => {
    username => 'owing_parent', user_type => 'parent',
    email => 'owing@test.example', name => 'Dana Owing',
} );

sub add_instalment ( $seq, $status, %opt ) {
    $db->insert( 'payments', {
        user_id          => $parent->id,
        amount_cents     => $opt{amount} // 10000,
        currency         => 'USD',
        status           => $status,
        instalment_seq   => $seq,
        instalment_count => 3,
        due_date         => $opt{due} // '2026-07-01',
        stripe_schedule_id => 'sub_sched_screen',
        error_message    => $opt{error},
        metadata         => { -json => {} },
    } );
}

subtest 'nothing outstanding reads as nothing outstanding' => sub {
    $t->get_ok('/admin/dashboard/outstanding_instalments')
      ->status_is(200)
      ->content_like( qr/Nothing outstanding/i,
          'rather than an empty table an operator has to interpret' );
};

subtest 'what is owed is listed, with the family and the instalment number' => sub {
    add_instalment( 1, 'completed' );
    add_instalment( 2, 'pending', due => '2026-08-01' );
    add_instalment( 3, 'pending', due => '2026-09-01' );

    $t->get_ok('/admin/dashboard/outstanding_instalments')
      ->status_is(200)
      ->content_like( qr/Dana Owing/,        'the family' )
      ->content_like( qr/owing\@test\.example/, 'and how to reach them' )
      ->content_like( qr/2 of 3/,            'which payment this is' )
      ->content_like( qr/200\.00 outstanding/, 'and what the total owed is' );

    # The paid one is not listed. An outstanding view that shows settled rows is
    # a ledger, and Morgan is not looking for a ledger.
    $t->content_unlike( qr/1 of 3/, 'the instalment already paid is not listed' );
};

subtest 'a failure says the child is still enrolled' => sub {
    $db->delete( 'payments', { stripe_schedule_id => 'sub_sched_screen' } );
    add_instalment( 1, 'completed' );
    add_instalment( 2, 'failed', due => '2026-08-01',
        error => 'Your card was declined.' );

    $t->get_ok('/admin/dashboard/outstanding_instalments')
      ->status_is(200)
      ->content_like( qr/Payment failed/i, 'the failure is visible' )
      ->content_like( qr/declined/,        'with the reason' )
      ->content_like( qr/1 need attention/, 'and counted separately from what is merely due' )
      # The sentence that stops a panicked phone call or a double-booked seat.
      ->content_like( qr/Still enrolled/i,
          'and it says the child kept their place' );
};

$t_db->cleanup_test_database;
