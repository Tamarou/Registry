# ABOUTME: Test::Mojo subclass that automatically injects CSRF tokens into form POST/PUT/DELETE requests.
# ABOUTME: Eliminates boilerplate CSRF token extraction from controller and integration tests.
use 5.40.2;

package Test::Registry::Mojo {
    use parent 'Test::Mojo';
    use Mojo::DOM;

    # Read the CSRF token from the most recently rendered response DOM.
    # Checks both hidden form inputs (server-injected) and the csrf-token meta tag.
    # Returns undef if no token is present (e.g., before any GET request).
    my sub _token_from_dom ($self) {
        my $dom = eval { $self->tx->res->dom };
        return undef unless $dom;

        # Prefer the hidden input injected into forms by the after_render hook
        my $input = $dom->at('input[name="csrf_token"]');
        return $input->attr('value') if $input;

        # Fall back to the meta tag present in all layouts
        my $meta = $dom->at('meta[name="csrf-token"]');
        return $meta ? $meta->attr('content') : undef;
    }

    # Obtain a CSRF token for the current Test::Mojo session.  If the last
    # response already contains the token in a hidden form input or meta tag,
    # use it directly.  Otherwise, perform a silent GET to "/" to establish
    # a session and acquire the token from the meta tag in the layout.
    my sub _ensure_csrf_token ($self) {
        my $token = _token_from_dom($self);
        return $token if defined $token;

        # No CSRF token available yet.  Silently GET "/" to establish a
        # session cookie.  The default layout includes a csrf-token meta tag.
        # We use the underlying UA directly to avoid emitting test assertion output.
        my $bootstrap_tx = $self->ua->get('/');
        my $bootstrap_dom = Mojo::DOM->new( $bootstrap_tx->res->body );

        my $meta = $bootstrap_dom->at('meta[name="csrf-token"]');
        return $meta ? $meta->attr('content') : undef;
    }

    # Inject csrf_token into a "form => \%hash" argument list if the token is
    # available and the caller has not already provided one.
    # When no form body is present at all, adds "form => { csrf_token => $token }"
    # so that bare post_ok($url) calls also pass CSRF validation.
    my sub _inject_csrf ( $csrf_token, @args ) {
        return @args unless $csrf_token;

        # Scan for an existing "form => \%hash" pair and inject token
        for my $i ( 0 .. $#args - 1 ) {
            if ( !ref $args[$i] && $args[$i] eq 'form' && ref $args[ $i + 1 ] eq 'HASH' ) {
                $args[ $i + 1 ]{csrf_token} //= $csrf_token;
                return @args;
            }
        }

        # No form body found — append one containing only the CSRF token so that
        # bare post_ok($url) calls also satisfy CSRF validation.
        push @args, ( form => { csrf_token => $csrf_token } );
        return @args;
    }

    sub post_ok {
        my ( $self, $url, @args ) = @_;
        local $Test::Builder::Level = $Test::Builder::Level + 1;
        my $token = _ensure_csrf_token($self);
        @args = _inject_csrf( $token, @args );
        return $self->SUPER::post_ok( $url, @args );
    }

    sub put_ok {
        my ( $self, $url, @args ) = @_;
        local $Test::Builder::Level = $Test::Builder::Level + 1;
        my $token = _ensure_csrf_token($self);
        @args = _inject_csrf( $token, @args );
        return $self->SUPER::put_ok( $url, @args );
    }

    sub delete_ok {
        my ( $self, $url, @args ) = @_;
        local $Test::Builder::Level = $Test::Builder::Level + 1;
        my $token = _ensure_csrf_token($self);
        @args = _inject_csrf( $token, @args );
        return $self->SUPER::delete_ok( $url, @args );
    }
}

1;
