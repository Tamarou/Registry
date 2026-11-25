#!/usr/bin/env perl
# ABOUTME: Tests that an in-flight Stripe request keeps its client alive until Stripe answers
# ABOUTME: Requests are answered by a local app, never sent to Stripe

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Mojolicious::Lite;
use Registry::Service::Stripe;
use Test::Registry::Async qw( settle );

app->log->level('fatal');
any '/*rest' => sub ($c) { $c->render( json => { id => 'sub_local', schedule => undef } ) };

# A client made for one call and kept by nobody, as the Connect webhook's
# subscription lookup and refund_platform_fee_async's platform client are:
# only the returned promise is left once this returns.
sub lookup () {
    my $client = Registry::Service::Stripe->new( api_key => 'sk_test_local' );
    $client->ua->server->app(app);
    $client->ua->on( prepare => sub ( $ua, $tx ) { $tx->req->url->scheme(undef) } );
    return $client->retrieve_subscription_async('sub_local');
}

my $got = eval { settle( lookup() ) };
is $@, '', 'the request is not cut off when its client goes out of scope';
is $got && $got->{id}, 'sub_local', 'and Stripe\'s answer arrives';

done_testing;
