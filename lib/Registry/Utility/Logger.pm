# ABOUTME: Structured JSON logger for Registry, subclasses Mojo::Log.
# ABOUTME: Outputs JSON-formatted log lines with timestamp, level, message, and request context.
use 5.42.0;
use Object::Pad;

class Registry::Utility::Logger :isa(Mojo::Log) {
    use Mojo::JSON   qw(encode_json decode_json);
    use Mojo::Util   qw(steady_time);
    use Scalar::Util qw(looks_like_number);

    # Per-instance request/user/tenant context stored as a plain hash ref
    field $_context = {};

    # Override the parent BUILD to set our JSON format callback and default level
    BUILD {
        $self->level( $ENV{LOG_LEVEL} // $self->level );
        $self->format( \&_json_format );
    }

    # Replace current context (call once per request with { request_id, user_id, tenant_id })
    method set_context ($ctx) {
        $_context = $ctx // {};
    }

    # Clear context (call at end of request)
    method clear_context () {
        $_context = {};
    }

    # The format sub used by Mojo::Log -- called as a plain function, not a method,
    # so it receives ($time, $level, @lines) and must not reference $self.
    # Context merging is handled by overriding the append method instead.
    sub _json_format {
        my ( $time, $level, @lines ) = @_;
        my $message = _redact( join( ' ', @lines ) );
        my $entry   = {
            timestamp => $time + 0,
            level     => $level,
            message   => $message,
        };
        return encode_json($entry) . "\n";
    }

    # Merge context into every log entry by overriding append.
    # Mojo::Log::append($msg) writes $msg to the handle; we intercept, parse,
    # inject context, and re-serialise before delegating.
    method append ($msg) {
        if ( %$_context ) {
            # Parse the JSON the format callback produced, merge context, re-encode
            $msg =~ s/\n\z//;
            my $entry = eval { decode_json($msg) };
            if ( $entry && ref $entry eq 'HASH' ) {
                for my $k ( keys %$_context ) {
                    $entry->{$k} = $_context->{$k};
                }
                $msg = encode_json($entry) . "\n";
            } else {
                # If decode failed for any reason, restore the newline and pass through
                $msg .= "\n";
            }
        }
        $self->SUPER::append($msg);
    }

    # Redact sensitive values from a log message string.
    # Patterns: key=value where key matches password/token/secret/authorization/api_key
    # Also redacts 13-19 digit card-number-like sequences.
    sub _redact {
        my ($msg) = @_;
        return $msg unless defined $msg;

        # Redact key=value pairs where the key is a sensitive name
        $msg =~ s{
            \b
            (password|token|secret|authorization|api_key|apikey|auth)
            \s*=\s*
            \S+
        }{$1=[REDACTED]}gxi;

        # Redact 13-19 digit sequences that look like card numbers
        $msg =~ s{\b([0-9]{13,19})\b}{[CARD-REDACTED]}g;

        return $msg;
    }
}
