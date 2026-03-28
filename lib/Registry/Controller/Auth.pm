# ABOUTME: Auth controller handling magic link login, email verification,
# ABOUTME: WebAuthn passkey flows, API key management, and logout for passwordless authentication.
use 5.42.0;
use utf8;
use Object::Pad;

class Registry::Controller::Auth :isa(Registry::Controller) {
    use Registry::DAO::User;
    use Registry::DAO::MagicLinkToken;
    use Registry::DAO::ApiKey;
    use Registry::DAO::Tenant;
    use Registry::Email::Template;
    use Email::Simple;
    use Email::Sender::Simple qw(sendmail);

    method login {
        $self->render(template => 'auth/login');
    }

    method request_magic_link {
        my $email = $self->param('email') // '';

        # Always show the same confirmation page regardless of whether
        # the email matched a user.  This prevents user enumeration.
        if ($email) {
            try {
                my $dao  = $self->dao;
                my $db   = $dao->db;
                my $user = Registry::DAO::User->find($db, { email => $email });

                if ($user) {
                    my $tenant = Registry::DAO::Tenant->find($db, { slug => $self->tenant });
                    my $expiry = $tenant ? $tenant->magic_link_expiry_hours : 24;

                    my ($token, $plaintext) =
                        Registry::DAO::MagicLinkToken->generate($db, {
                            user_id    => $user->id,
                            purpose    => 'login',
                            expires_in => $expiry,
                        });

                    # Build the full magic link URL from the current request base
                    my $base_url = $self->req->url->base->to_string;
                    $base_url =~ s{/$}{};
                    my $magic_link_url = "$base_url/auth/magic/$plaintext";

                    # Determine tenant name for the email subject and greeting
                    my $tenant_name = $tenant ? $tenant->name : 'Registry';

                    # Render the magic link email template (html + text)
                    my $rendered = Registry::Email::Template->render(
                        'magic_link_login',
                        tenant_name      => $tenant_name,
                        magic_link_url   => $magic_link_url,
                        expires_in_hours => $expiry,
                    );

                    # Build a multipart/alternative MIME message manually
                    my $boundary = 'registry_' . sprintf('%x', int(rand(0xFFFFFFFF)));
                    my $mime_body = join('',
                        "--$boundary\r\n",
                        "Content-Type: text/plain; charset=UTF-8\r\n",
                        "Content-Transfer-Encoding: quoted-printable\r\n",
                        "\r\n",
                        $rendered->{text},
                        "\r\n",
                        "--$boundary\r\n",
                        "Content-Type: text/html; charset=UTF-8\r\n",
                        "Content-Transfer-Encoding: quoted-printable\r\n",
                        "\r\n",
                        $rendered->{html},
                        "\r\n",
                        "--$boundary--\r\n",
                    );

                    my $mail = Email::Simple->create(
                        header => [
                            To             => $email,
                            From           => $ENV{NOTIFICATION_FROM_EMAIL} || 'noreply@registry.example.com',
                            Subject        => "Sign in to $tenant_name",
                            'MIME-Version' => '1.0',
                            'Content-Type' => "multipart/alternative; boundary=\"$boundary\"",
                        ],
                        body => $mime_body,
                    );

                    sendmail($mail);
                    $self->app->log->info("Magic link email sent to $email");
                }
            }
            catch ($e) {
                $self->app->log->warn("Error during magic link request: $e");
            }
        }

        $self->render(template => 'auth/magic-link-sent');
    }

    method consume_magic_link {
        my $plaintext = $self->param('token') // '';
        my $dao       = $self->dao;
        my $db        = $dao->db;

        my $token = Registry::DAO::MagicLinkToken->find_by_plaintext($db, $plaintext);

        unless ($token) {
            $self->stash(error => 'This link is invalid.');
            return $self->render(template => 'auth/magic-link-error');
        }

        if ($token->consumed_at) {
            $self->stash(error => 'This link has already been used.');
            return $self->render(template => 'auth/magic-link-error');
        }

        if ($token->is_expired) {
            $self->stash(error => 'This link has expired. Please request a new one.');
            return $self->render(template => 'auth/magic-link-error');
        }

        try {
            $token->consume($db);

            # Set the user session
            $self->session(user_id => $token->user_id);

            $self->redirect_to('/');
        }
        catch ($e) {
            $self->app->log->warn("Error consuming magic link: $e");
            $self->stash(error => 'This link is invalid or has expired.');
            $self->render(template => 'auth/magic-link-error');
        }
    }

    method verify_email {
        my $plaintext = $self->param('token') // '';
        my $dao       = $self->dao;
        my $db        = $dao->db;

        my $token = Registry::DAO::MagicLinkToken->find_by_plaintext($db, $plaintext);

        unless ($token && $token->purpose eq 'verify_email') {
            $self->stash(verified => 0, error => 'This verification link is invalid.');
            return $self->render(template => 'auth/verify-email');
        }

        if ($token->consumed_at || $token->is_expired) {
            $self->stash(verified => 0, error => 'This verification link has expired or was already used.');
            return $self->render(template => 'auth/verify-email');
        }

        try {
            $token->consume($db);

            # Mark the user's email as verified
            my $user = Registry::DAO::User->find($db, { id => $token->user_id });
            $user->update($db, { email_verified_at => \'now()' }) if $user;

            $self->stash(verified => 1);
            $self->render(template => 'auth/verify-email');
        }
        catch ($e) {
            $self->app->log->warn("Error verifying email: $e");
            $self->stash(verified => 0, error => 'Verification failed. Please try again.');
            $self->render(template => 'auth/verify-email');
        }
    }

    method logout {
        $self->session(expires => 1);
        $self->redirect_to('/');
    }

    # WebAuthn endpoints -- stubs for future implementation
    method webauthn_register_begin {
        $self->render(json => { error => 'Not yet implemented' }, status => 501);
    }

    method webauthn_register_complete {
        $self->render(json => { error => 'Not yet implemented' }, status => 501);
    }

    method webauthn_auth_begin {
        $self->render(json => { error => 'Not yet implemented' }, status => 501);
    }

    method webauthn_auth_complete {
        $self->render(json => { error => 'Not yet implemented' }, status => 501);
    }

    method create_api_key () {
        return unless $self->require_auth;

        my $user_id = $self->stash('current_user')->{id};
        my $dao     = $self->dao;
        my $db      = $dao->db;

        my $name = $self->param('name') // 'Unnamed Key';

        my $scopes_raw = $self->param('scopes') // 0;
        $scopes_raw = 0 unless $scopes_raw =~ /\A\d+\z/;

        my ($key_obj, $plaintext) = Registry::DAO::ApiKey->generate($db, {
            user_id => $user_id,
            name    => $name,
            scopes  => int($scopes_raw),
        });

        $self->render(json => {
            id         => $key_obj->id,
            key        => $plaintext,
            key_prefix => $key_obj->key_prefix,
            name       => $key_obj->name,
            created_at => $key_obj->created_at,
        });
    }

    method list_api_keys () {
        return unless $self->require_auth;

        my $user_id = $self->stash('current_user')->{id};
        my $dao     = $self->dao;
        my $db      = $dao->db;

        my @keys = map {
            {
                id         => $_->id,
                key_prefix => $_->key_prefix,
                name       => $_->name,
                scopes     => $_->scopes,
                last_used  => $_->last_used_at,
                created_at => $_->created_at,
            }
        } Registry::DAO::ApiKey->find($db, { user_id => $user_id });

        $self->render(json => \@keys);
    }
}

1;
