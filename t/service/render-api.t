#!/usr/bin/env perl
# ABOUTME: Tests for Registry::Service::Render custom domain API client
# ABOUTME: Uses a mock Mojo::UserAgent to exercise all domain management methods without live HTTP

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use Mojo::JSON qw(encode_json decode_json);

use_ok('Registry::Service::Render');

# ---------------------------------------------------------------------------
# Mock UA helpers
# ---------------------------------------------------------------------------
# These packages replace only the external HTTP boundary (Mojo::UserAgent),
# leaving all internal business logic in Registry::Service::Render untouched.

package MockResponse;
sub new {
    my ($class, %args) = @_;
    return bless { code => $args{code} // 200, body => $args{body} // '{}' }, $class;
}
sub code       { $_[0]->{code} }
sub body       { $_[0]->{body} }
sub is_success { $_[0]->{code} >= 200 && $_[0]->{code} < 300 }
sub json       { Mojo::JSON::decode_json($_[0]->{body}) }

package MockTx;
sub new {
    my ($class, $res) = @_;
    return bless { res => $res }, $class;
}
sub res    { $_[0]->{res} }
sub result { $_[0]->{res} }

package MockUA;
sub new {
    my ($class, %routes) = @_;
    return bless { routes => \%routes }, $class;
}
sub _dispatch {
    my ($self, $method, $url) = @_;
    my $key = "$method $url";
    if (my $r = $self->{routes}{$key}) {
        return MockTx->new(MockResponse->new(%$r));
    }
    return MockTx->new(MockResponse->new(code => 404, body => '{"error":"not found"}'));
}
sub post   { my ($self, $url, @rest) = @_; $self->_dispatch('POST',   $url) }
sub get    { my ($self, $url, @rest) = @_; $self->_dispatch('GET',    $url) }
sub delete { my ($self, $url, @rest) = @_; $self->_dispatch('DELETE', $url) }

package RecordingUA;
sub new { bless { calls => [] }, shift }
sub post {
    my ($self, $url, @rest) = @_;
    push @{ $self->{calls} }, "POST $url";
    return MockTx->new(MockResponse->new(code => 200, body => '{"id":"x","status":"ok"}'));
}
sub get {
    my ($self, $url, @rest) = @_;
    push @{ $self->{calls} }, "GET $url";
    return MockTx->new(MockResponse->new(code => 200, body => '{"id":"x","status":"ok"}'));
}
sub delete {
    my ($self, $url, @rest) = @_;
    push @{ $self->{calls} }, "DELETE $url";
    return MockTx->new(MockResponse->new(code => 204, body => '{}'));
}

package main;

# ---------------------------------------------------------------------------
# Shared test fixtures
# ---------------------------------------------------------------------------

my $API_KEY    = 'rnd_test_abc123';
my $SERVICE_ID = 'srv-test-abc';
my $BASE_URL   = 'https://api.render.com/v1';
my $DOMAIN_ID  = 'cdm-abc123';
my $DOMAIN     = 'example.com';

# ---------------------------------------------------------------------------
# Module loads and instantiates
# ---------------------------------------------------------------------------

subtest 'Module loads and instantiates' => sub {
    my $render = Registry::Service::Render->new(
        api_key    => $API_KEY,
        service_id => $SERVICE_ID,
    );
    ok($render, 'Registry::Service::Render instantiated');
    isa_ok($render, 'Registry::Service::Render');

    # Reader accessors created by :reader
    is($render->api_key,    $API_KEY,    'api_key reader returns correct value');
    is($render->service_id, $SERVICE_ID, 'service_id reader returns correct value');
};

# ---------------------------------------------------------------------------
# add_custom_domain
# ---------------------------------------------------------------------------

subtest 'add_custom_domain - success' => sub {
    my $url  = "$BASE_URL/services/$SERVICE_ID/custom-domains";
    my $body = encode_json({ id => $DOMAIN_ID, name => $DOMAIN, status => 'unverified' });

    my $ua = MockUA->new("POST $url" => { code => 201, body => $body });
    my $render = Registry::Service::Render->new(
        api_key    => $API_KEY,
        service_id => $SERVICE_ID,
        ua         => $ua,
    );

    my $result;
    lives_ok { $result = $render->add_custom_domain($DOMAIN) } 'add_custom_domain lives';
    is($result->{id},     $DOMAIN_ID,   'returns domain id');
    is($result->{name},   $DOMAIN,      'returns domain name');
    is($result->{status}, 'unverified', 'returns domain status');
};

subtest 'add_custom_domain - API error propagates' => sub {
    my $url = "$BASE_URL/services/$SERVICE_ID/custom-domains";
    my $ua  = MockUA->new("POST $url" => { code => 422, body => '{"error":"domain already exists"}' });
    my $render = Registry::Service::Render->new(
        api_key    => $API_KEY,
        service_id => $SERVICE_ID,
        ua         => $ua,
    );

    throws_ok { $render->add_custom_domain($DOMAIN) }
        qr/Render API error/,
        'add_custom_domain throws on API error';
};

# ---------------------------------------------------------------------------
# verify_custom_domain
# ---------------------------------------------------------------------------

subtest 'verify_custom_domain - success' => sub {
    my $url  = "$BASE_URL/services/$SERVICE_ID/custom-domains/$DOMAIN_ID/verify";
    my $body = encode_json({ id => $DOMAIN_ID, status => 'verified' });

    my $ua = MockUA->new("POST $url" => { code => 200, body => $body });
    my $render = Registry::Service::Render->new(
        api_key    => $API_KEY,
        service_id => $SERVICE_ID,
        ua         => $ua,
    );

    my $result;
    lives_ok { $result = $render->verify_custom_domain($DOMAIN_ID) } 'verify_custom_domain lives';
    is($result->{status}, 'verified', 'returns verified status');
};

subtest 'verify_custom_domain - API error propagates' => sub {
    my $url = "$BASE_URL/services/$SERVICE_ID/custom-domains/$DOMAIN_ID/verify";
    my $ua  = MockUA->new("POST $url" => { code => 400, body => '{"error":"verification failed"}' });
    my $render = Registry::Service::Render->new(
        api_key    => $API_KEY,
        service_id => $SERVICE_ID,
        ua         => $ua,
    );

    throws_ok { $render->verify_custom_domain($DOMAIN_ID) }
        qr/Render API error/,
        'verify_custom_domain throws on API error';
};

# ---------------------------------------------------------------------------
# remove_custom_domain
# ---------------------------------------------------------------------------

subtest 'remove_custom_domain - success' => sub {
    my $url = "$BASE_URL/services/$SERVICE_ID/custom-domains/$DOMAIN_ID";
    my $ua  = MockUA->new("DELETE $url" => { code => 204, body => '{}' });
    my $render = Registry::Service::Render->new(
        api_key    => $API_KEY,
        service_id => $SERVICE_ID,
        ua         => $ua,
    );

    my $result;
    lives_ok { $result = $render->remove_custom_domain($DOMAIN_ID) } 'remove_custom_domain lives';
    is($result, 1, 'remove_custom_domain returns 1 on success');
};

subtest 'remove_custom_domain - API error propagates' => sub {
    my $url = "$BASE_URL/services/$SERVICE_ID/custom-domains/$DOMAIN_ID";
    my $ua  = MockUA->new("DELETE $url" => { code => 404, body => '{"error":"not found"}' });
    my $render = Registry::Service::Render->new(
        api_key    => $API_KEY,
        service_id => $SERVICE_ID,
        ua         => $ua,
    );

    throws_ok { $render->remove_custom_domain($DOMAIN_ID) }
        qr/Render API error/,
        'remove_custom_domain throws on API error';
};

# ---------------------------------------------------------------------------
# get_custom_domain
# ---------------------------------------------------------------------------

subtest 'get_custom_domain - success' => sub {
    my $url  = "$BASE_URL/services/$SERVICE_ID/custom-domains/$DOMAIN_ID";
    my $body = encode_json({ id => $DOMAIN_ID, name => $DOMAIN, status => 'verified' });

    my $ua = MockUA->new("GET $url" => { code => 200, body => $body });
    my $render = Registry::Service::Render->new(
        api_key    => $API_KEY,
        service_id => $SERVICE_ID,
        ua         => $ua,
    );

    my $result;
    lives_ok { $result = $render->get_custom_domain($DOMAIN_ID) } 'get_custom_domain lives';
    is($result->{id},     $DOMAIN_ID, 'returns domain id');
    is($result->{name},   $DOMAIN,    'returns domain name');
    is($result->{status}, 'verified', 'returns domain status');
};

subtest 'get_custom_domain - API error propagates' => sub {
    my $url = "$BASE_URL/services/$SERVICE_ID/custom-domains/$DOMAIN_ID";
    my $ua  = MockUA->new("GET $url" => { code => 404, body => '{"error":"not found"}' });
    my $render = Registry::Service::Render->new(
        api_key    => $API_KEY,
        service_id => $SERVICE_ID,
        ua         => $ua,
    );

    throws_ok { $render->get_custom_domain($DOMAIN_ID) }
        qr/Render API error/,
        'get_custom_domain throws on API error';
};

# ---------------------------------------------------------------------------
# Public API surface
# ---------------------------------------------------------------------------

subtest 'Public API methods exist' => sub {
    my $render = Registry::Service::Render->new(
        api_key    => $API_KEY,
        service_id => $SERVICE_ID,
    );
    can_ok($render, qw(add_custom_domain verify_custom_domain remove_custom_domain get_custom_domain));
};

# ---------------------------------------------------------------------------
# Correct URL construction
# ---------------------------------------------------------------------------

subtest 'URLs are constructed correctly' => sub {
    my $ua = RecordingUA->new;
    my $render = Registry::Service::Render->new(
        api_key    => $API_KEY,
        service_id => $SERVICE_ID,
        ua         => $ua,
    );

    $render->add_custom_domain('foo.example.com');
    $render->verify_custom_domain($DOMAIN_ID);
    $render->get_custom_domain($DOMAIN_ID);
    $render->remove_custom_domain($DOMAIN_ID);

    my @recorded = @{ $ua->{calls} };
    is($recorded[0], "POST $BASE_URL/services/$SERVICE_ID/custom-domains",
        'add_custom_domain POSTs to correct URL');
    is($recorded[1], "POST $BASE_URL/services/$SERVICE_ID/custom-domains/$DOMAIN_ID/verify",
        'verify_custom_domain POSTs to correct URL');
    is($recorded[2], "GET $BASE_URL/services/$SERVICE_ID/custom-domains/$DOMAIN_ID",
        'get_custom_domain GETs correct URL');
    is($recorded[3], "DELETE $BASE_URL/services/$SERVICE_ID/custom-domains/$DOMAIN_ID",
        'remove_custom_domain DELETEs correct URL');
};

done_testing;
