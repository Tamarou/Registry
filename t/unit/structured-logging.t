# ABOUTME: Unit tests for structured JSON logging via Registry::Utility::Logger.
# ABOUTME: Verifies JSON format, required fields, request context, and sensitive data redaction.
use 5.42.0;
use lib          qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw( done_testing is ok like unlike diag )];
defer { done_testing };

use Mojo::JSON qw(decode_json);
use Scalar::Util qw(looks_like_number);

use Registry::Utility::Logger;

# Helper: capture log output written to a scalar
sub capture_log {
    my ($level, $message, $context) = @_;
    my $buf = '';
    open my $fh, '>', \$buf or die "Cannot open scalar ref: $!";
    my $logger = Registry::Utility::Logger->new(handle => $fh, level => 'debug');
    if ($context) {
        $logger->set_context($context);
    }
    $logger->$level($message);
    close $fh;
    return $buf;
}

# --- JSON structure tests ---

{
    my $output = capture_log('info', 'test message');
    ok length($output) > 0, 'logger produces output';

    my $data = eval { decode_json($output) };
    ok !$@, "log output is valid JSON (error: $@)";
    ok defined $data, 'decoded to defined value';

    ok exists $data->{timestamp}, 'JSON has timestamp field';
    ok exists $data->{level},     'JSON has level field';
    ok exists $data->{message},   'JSON has message field';

    ok looks_like_number($data->{timestamp}), 'timestamp is numeric';
    is $data->{level},   'info',         'level is correct';
    is $data->{message}, 'test message', 'message is correct';
}

# --- Log levels ---

{
    for my $level (qw( debug info warn error fatal )) {
        my $output = capture_log($level, "testing $level");
        my $data = eval { decode_json($output) };
        ok !$@,                      "$level: output is valid JSON";
        is $data->{level}, $level,   "$level: level field correct";
        is $data->{message}, "testing $level", "$level: message correct";
    }
}

# --- Request context (request_id) ---

{
    my $buf = '';
    open my $fh, '>', \$buf or die $!;
    my $logger = Registry::Utility::Logger->new(handle => $fh, level => 'debug');
    $logger->set_context({ request_id => 'req-abc-123' });
    $logger->info('with request context');
    close $fh;

    my $data = eval { decode_json($buf) };
    ok !$@, 'request context log is valid JSON';
    is $data->{request_id}, 'req-abc-123', 'request_id included in log output';
}

# --- User and tenant context ---

{
    my $buf = '';
    open my $fh, '>', \$buf or die $!;
    my $logger = Registry::Utility::Logger->new(handle => $fh, level => 'debug');
    $logger->set_context({ user_id => 42, tenant_id => 'acme' });
    $logger->info('with user and tenant');
    close $fh;

    my $data = eval { decode_json($buf) };
    ok !$@,                          'user/tenant context log is valid JSON';
    is $data->{user_id},   42,       'user_id included in log output';
    is $data->{tenant_id}, 'acme',   'tenant_id included in log output';
}

# --- Sensitive field redaction ---

{
    # password in message string should be redacted
    my $output = capture_log('info', 'user password=secret123 logged in');
    my $data = eval { decode_json($output) };
    ok !$@, 'sensitive message is valid JSON';
    unlike $data->{message}, qr/secret123/, 'raw password value is redacted from message';
    like   $data->{message}, qr/password=\[REDACTED\]/, 'password field shows REDACTED marker';
}

{
    # token in message string should be redacted
    my $output = capture_log('info', 'token=abc123xyz used for auth');
    my $data = eval { decode_json($output) };
    ok !$@, 'token message is valid JSON';
    unlike $data->{message}, qr/abc123xyz/, 'raw token value is redacted';
    like   $data->{message}, qr/token=\[REDACTED\]/, 'token shows REDACTED marker';
}

{
    # secret in message string should be redacted
    my $output = capture_log('warn', 'secret=mysecretvalue exposed');
    my $data = eval { decode_json($output) };
    ok !$@, 'secret message is valid JSON';
    unlike $data->{message}, qr/mysecretvalue/, 'raw secret value is redacted';
    like   $data->{message}, qr/secret=\[REDACTED\]/, 'secret shows REDACTED marker';
}

{
    # card number pattern should be redacted
    my $output = capture_log('info', 'processing card 4111111111111111 for payment');
    my $data = eval { decode_json($output) };
    ok !$@, 'card number message is valid JSON';
    unlike $data->{message}, qr/4111111111111111/, 'raw card number is redacted';
    like   $data->{message}, qr/\[CARD-REDACTED\]/, 'card number shows CARD-REDACTED marker';
}

# --- Level filtering ---

{
    my $buf = '';
    open my $fh, '>', \$buf or die $!;
    my $logger = Registry::Utility::Logger->new(handle => $fh, level => 'warn');
    $logger->debug('this should not appear');
    $logger->info('this should not appear either');
    $logger->warn('this should appear');
    close $fh;

    my @lines = split /\n/, $buf;
    is scalar(@lines), 1, 'only one log line emitted at warn level';
    my $data = eval { decode_json($lines[0]) };
    is $data->{level}, 'warn', 'only warn-level message emitted';
}

# --- LOG_LEVEL env var respected at construction ---

{
    local $ENV{LOG_LEVEL} = 'error';
    my $logger = Registry::Utility::Logger->new;
    is $logger->level, 'error', 'LOG_LEVEL env var sets default level';
}
