# ABOUTME: Rate limiting middleware for Registry, using a fixed window counter per IP/user.
# ABOUTME: In-memory counters reset on server restart (acceptable for MVP; use Redis for multi-process).

use 5.42.0;

package Registry::Middleware::RateLimit;

# --- Configuration constants ---

# Auth-sensitive route patterns (login, signup) - tighter limit
our @AUTH_PATHS = qw(
    login
    signup
    register
    tenant-signup
    password
);

# Route prefixes that bypass rate limiting entirely
our @EXCLUDED_PREFIXES = qw(
    /webhooks/
    /static/
    /public/
);

our $AUTH_LIMIT      = 10;   # requests per window
our $GENERAL_LIMIT   = 100;  # requests per window
our $WINDOW_SECONDS  = 60;   # sliding window duration

# Package-level store: { "$key" => { count => N, window_start => epoch } }
# NOTE: This state is per-process and resets on server restart. For a
# multi-process (prefork) deployment, a shared store such as Redis is needed.
my %_counters;

# --- Public interface ---

sub new ($class, %args) {
    return bless {}, $class;
}

# Returns the rate-limit key for a request context.
# Uses authenticated user ID when available, otherwise falls back to IP.
sub _request_key ($class_or_self, $c) {
    my $ip = $c->req->headers->header('X-Forwarded-For')
          // $c->tx->remote_address
          // '127.0.0.1';
    # Take only the first IP in case of a list ("client, proxy1, proxy2")
    $ip =~ s/,.*$//;
    $ip =~ s/\s+//g;
    return $ip;
}

# Determines the applicable limit (auth vs general) for a given path.
sub _limit_for_path ($class_or_self, $path) {
    for my $auth_segment (@AUTH_PATHS) {
        return $AUTH_LIMIT if $path =~ m{(?:^|/)$auth_segment(?:/|$)};
    }
    return $GENERAL_LIMIT;
}

# Returns true if this path is excluded from rate limiting.
sub _is_excluded ($class_or_self, $path) {
    for my $prefix (@EXCLUDED_PREFIXES) {
        return 1 if index($path, $prefix) == 0;
    }
    return 0;
}

# Evict expired entries to prevent unbounded memory growth.
# Called on every request (cheap linear scan; fine for MVP load levels).
sub _evict_expired ($class_or_self) {
    my $now  = time();
    my @keys = keys %_counters;
    for my $key (@keys) {
        if ($now - $_counters{$key}{window_start} >= $WINDOW_SECONDS) {
            delete $_counters{$key};
        }
    }
}

# Core check: increments counter and returns (allowed => bool, retry_after => seconds).
sub check ($class_or_self, $key, $limit) {
    my $now = time();

    $class_or_self->_evict_expired();

    my $entry = $_counters{$key};

    if (!$entry || ($now - $entry->{window_start} >= $WINDOW_SECONDS)) {
        # Start a fresh window
        $_counters{$key} = { count => 1, window_start => $now };
        return (allowed => 1, retry_after => 0);
    }

    $entry->{count}++;

    if ($entry->{count} > $limit) {
        my $retry_after = $WINDOW_SECONDS - ($now - $entry->{window_start});
        $retry_after = 1 if $retry_after < 1;
        return (allowed => 0, retry_after => $retry_after);
    }

    return (allowed => 1, retry_after => 0);
}

# Mojolicious before_dispatch hook handler.
# Attach via: $app->hook(before_dispatch => \&Registry::Middleware::RateLimit::before_dispatch);
sub before_dispatch ($class_or_self, $c) {
    my $path = $c->req->url->path->to_string;

    return if $class_or_self->_is_excluded($path);

    my $key   = $class_or_self->_request_key($c);
    my $limit = $class_or_self->_limit_for_path($path);

    my %result = $class_or_self->check($key, $limit);

    unless ($result{allowed}) {
        my $retry_after = $result{retry_after};

        $c->res->headers->header('Retry-After' => $retry_after);

        $c->render(
            status => 429,
            json   => {
                error       => 'Rate limit exceeded. Please try again later.',
                retry_after => $retry_after,
            },
        );

        $c->rendered(429);
    }
}

1;
