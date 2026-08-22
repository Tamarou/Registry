#!/usr/bin/env perl
# ABOUTME: An invoice whose subscription lookup fails must retry; one with no subscription must not.
# ABOUTME: Dying on a permanent condition is a poison pill that gets the endpoint disabled.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Object::Pad;
use Test::Registry::DB;
use Registry::DAO::Subscription;

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_subscription_resolution';

# A subscription client whose Stripe lookup always fails, the way
# _stripe_request does on any API error: it warns and returns undef. No packet
# leaves the box.
class Test::Subscription::LookupFails :isa(Registry::DAO::Subscription) {
    method get_subscription ($id) { return undef }
}

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $subs  = Registry::DAO::Subscription->new( db => $dao );
my $fails = Test::Subscription::LookupFails->new( db => $dao );

sub invoice ($object) { { object => $object } }

# Which location the id arrives in is decided by the endpoint's API version in
# the Stripe Dashboard, outside this code entirely.
subtest 'the subscription id is read from both API-version locations' => sub {
    is $subs->_invoice_subscription_id({ subscription => 'sub_top' }), 'sub_top',
        'the pre-2025 top-level field';
    is $subs->_invoice_subscription_id(
        { parent => { subscription_details => { subscription => 'sub_nested' } } } ),
        'sub_nested', 'the newer nested location';
    is $subs->_invoice_subscription_id(
        { subscription => '',
          parent => { subscription_details => { subscription => 'sub_nested' } } } ),
        'sub_nested', 'an empty top-level field falls through rather than winning';
    is $subs->_invoice_subscription_id({ id => 'in_oneoff' }), undef,
        'a one-off invoice yields no id at all';
};

# TRANSIENT. The invoice names a subscription and Stripe could not be reached.
# A retry can succeed, so this must fail loudly: dying rolls back the dedup
# claim, and Stripe redelivers.
subtest 'a lookup failure dies so the dedup claim is released and Stripe retries' => sub {
    for my $handler (qw( _handle_payment_failed _handle_payment_succeeded )) {
        my $err = do {
            local $@;
            eval { $fails->$handler( $db, invoice({ id => 'in_x', subscription => 'sub_gone' }) ) };
            $@;
        };
        like $err, qr/Cannot resolve subscription sub_gone/,
            "$handler dies when the named subscription cannot be fetched";
    }
};

# PERMANENT. One-off invoices are real and no retry makes one grow a
# subscription. Dying would mean ~3 days of 500s, after which Stripe disables
# the endpoint -- and payment_intent.succeeded stops arriving with it, taking
# the enrollment safety net down. This is the regression that matters most in
# this file: an earlier version died here.
subtest 'an invoice with no subscription is a quiet no-op, not a poison pill' => sub {
    for my $handler (qw( _handle_payment_failed _handle_payment_succeeded )) {
        my @warnings;
        my $err = do {
            local $SIG{__WARN__} = sub { push @warnings, @_ };
            local $@;
            eval { $fails->$handler( $db, invoice({ id => 'in_oneoff' }) ); 1 };
            $@;
        };
        is $err, '', "$handler does not die on a one-off invoice";
        ok scalar(grep { /no subscription id/i } @warnings),
            "$handler says so rather than vanishing silently";
    }
};

# metadata is free-form text an operator can edit in the Dashboard. A non-UUID
# value aborts the transaction inside update_billing_status -- again permanent,
# again answered with an endless retry loop. The three sibling handlers have
# always guarded this; these two did not.
subtest 'a garbage tenant_id is refused rather than aborting the transaction' => sub {
    for my $bad ( 'some-tenant-slug', '../../etc', '00000000-0000-0000-0000-000000000000' ) {
        my $sub = { id => 'sub_ok', metadata => { tenant_id => $bad } };
        for my $handler (qw( _handle_payment_failed _handle_payment_succeeded )) {
            my $err = do {
                local $@;
                eval { $subs->$handler( $db, invoice({ id => 'in_y' }), $sub ); 1 };
                $@;
            };
            is $err, '', "$handler survives tenant_id '$bad'";
        }
    }
};

# Ours, but the metadata was dropped. Retrying changes nothing, so it is
# processed -- but a non-paying tenant that never reaches past_due is the one
# branch here that silently costs money, so it must not be mute.
subtest 'a subscription with no tenant_id warns rather than passing quietly' => sub {
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    $subs->_handle_payment_failed( $db, invoice({ id => 'in_z' }),
        { id => 'sub_no_tenant', metadata => {} } );
    ok scalar(grep { /no.*metadata\.tenant_id/i } @warnings),
        'the missing-tenant case is logged';
};

# The blocking Stripe call in these handlers can run inside the webhook's
# settlement transaction via the //= fallback, holding the dedup claim for its
# duration. Registry::Service::Stripe sets both timeouts; this client had
# neither.
subtest 'the Stripe user agent is bounded' => sub {
    my $ua = $subs->ua;

    # request_timeout is the one that matters and the only one this can grade.
    # Mojo::UserAgent defaults it to 0 -- unbounded -- so a bare UA fails here.
    is $ua->request_timeout, 30, 'request_timeout is bounded';

    # connect_timeout is asserted for the record, not as a gate: Mojo already
    # defaults it to 10, so the explicit call in Subscription.pm restates the
    # default and no assertion here can tell whether the line is present. Two
    # earlier forms of this check (`> 0`, then `is ..., 10`) both looked like
    # gates and were tautologies. Kept because a future Mojo changing the
    # default should be loud, but it grades Mojo, not us.
    is $ua->connect_timeout, 10, 'connect_timeout is 10 (Mojo default, restated)';
};

done_testing;
