# ABOUTME: Tests that /auth/magic/request uses the tight auth rate limit (10/min).
# ABOUTME: Verifies the magic-link request endpoint is not left on the general 100/min limit.

use 5.42.0;
use FindBin qw($Bin);
use lib "$Bin/../../lib", "$Bin/../lib", "lib", "t/lib";
use experimental qw(defer);
use Test::More import => [qw( done_testing is isnt ok plan subtest )];
defer { done_testing };

use Registry::Middleware::RateLimit;

# /auth/magic/request issues a magic-link email and consumes a token-generation
# budget.  It must be limited at the AUTH_LIMIT (10/min), not the GENERAL_LIMIT
# (100/min), to prevent email bombing and account enumeration.

subtest '_limit_for_path returns AUTH_LIMIT for /auth/magic/request' => sub {
    my $rl = Registry::Middleware::RateLimit->new;

    my $limit = $rl->_limit_for_path('/auth/magic/request');
    is $limit, $Registry::Middleware::RateLimit::AUTH_LIMIT,
        '/auth/magic/request gets the AUTH_LIMIT (10), not the GENERAL_LIMIT (100)';
};

subtest '_limit_for_path returns GENERAL_LIMIT for unrelated auth paths' => sub {
    my $rl = Registry::Middleware::RateLimit->new;

    # /auth/magic/poll/ is in @EXCLUDED_PREFIXES and never reaches _limit_for_path,
    # but if it did it must NOT accidentally match the magic/request pattern.
    my $poll_limit = $rl->_limit_for_path('/auth/magic/poll/abc123');
    is $poll_limit, $Registry::Middleware::RateLimit::GENERAL_LIMIT,
        '/auth/magic/poll/... does not match the magic/request auth pattern';

    # Other /auth/ paths that are not login, password, or magic/request
    my $other_limit = $rl->_limit_for_path('/auth/webauthn/auth/begin');
    is $other_limit, $Registry::Middleware::RateLimit::GENERAL_LIMIT,
        'non-auth-sensitive /auth/... paths still get GENERAL_LIMIT';
};

subtest '_limit_for_path still returns AUTH_LIMIT for existing auth patterns' => sub {
    my $rl = Registry::Middleware::RateLimit->new;

    is $rl->_limit_for_path('/login'),
        $Registry::Middleware::RateLimit::AUTH_LIMIT,
        '/login still gets AUTH_LIMIT after adding magic/request';

    is $rl->_limit_for_path('/auth/password'),
        $Registry::Middleware::RateLimit::AUTH_LIMIT,
        '/auth/password still gets AUTH_LIMIT after adding magic/request';
};
