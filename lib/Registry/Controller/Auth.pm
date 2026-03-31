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
    use Registry::DAO::Notification;
    use Registry::DAO::Passkey;
    use Registry::Auth::WebAuthn;
    use Registry::Auth::WebAuthn::Challenge;
    use MIME::Base64 qw(decode_base64url);

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

                    my $notification = Registry::DAO::Notification->create($db, {
                        user_id  => $user->id,
                        type     => 'magic_link_login',
                        channel  => 'email',
                        subject  => "Sign in to $tenant_name",
                        message  => "Magic link login for $email",
                        metadata => {
                            tenant_name      => $tenant_name,
                            magic_link_url   => $magic_link_url,
                            expires_in_hours => $expiry,
                        },
                    });
                    $notification->send($db);
                    $self->app->log->info("Magic link email sent to $email");
                    $self->stash(token_hash => $token->token_hash);
                }
            }
            catch ($e) {
                $self->app->log->warn("Error during magic link request: $e");
            }
        }

        $self->render(template => 'auth/magic-link-sent');
    }

    method verify_magic_link {
        my $plaintext = $self->param('token') // '';
        my $dao       = $self->dao;
        my $db        = $dao->db;

        my $token = Registry::DAO::MagicLinkToken->find_by_plaintext($db, $plaintext);

        unless ($token) {
            $self->stash(error => 'This link is invalid.');
            return $self->render(template => 'auth/magic-link-error');
        }

        if ($token->consumed_at) {
            $self->stash(already_signed_in => 1);
            return $self->render(template => 'auth/magic-link-confirm');
        }

        if ($token->is_expired) {
            $self->stash(error => 'This link has expired. Please request a new one.');
            return $self->render(template => 'auth/magic-link-error');
        }

        try {
            $token = $token->verify($db);
        }
        catch ($e) {
            # Already verified is harmless -- render the confirmation page anyway
            $self->app->log->debug("verify_magic_link: $e") if $e =~ /already verified/i;
        }

        $self->stash(plaintext => $plaintext);
        $self->render(template => 'auth/magic-link-confirm');
    }

    method complete_magic_link {
        my $plaintext = $self->param('token') // '';
        my $dao       = $self->dao;
        my $db        = $dao->db;

        my $token = Registry::DAO::MagicLinkToken->find_by_plaintext($db, $plaintext);

        unless ($token) {
            $self->stash(error => 'This link is invalid.');
            return $self->render(template => 'auth/magic-link-error');
        }

        if ($token->is_expired) {
            $self->stash(error => 'This link has expired. Please request a new one.');
            return $self->render(template => 'auth/magic-link-error');
        }

        try {
            $token->consume($db);

            $self->session(
                user_id          => $token->user_id,
                tenant_schema    => $self->tenant,
                authenticated_at => time(),
            );

            if ($token->purpose eq 'invite') {
                return $self->redirect_to('/auth/register-passkey');
            }

            $self->redirect_to('/');
        }
        catch ($e) {
            if ($e =~ /already consumed/i) {
                $self->stash(already_signed_in => 1);
                return $self->render(template => 'auth/magic-link-confirm');
            }
            if ($e =~ /not yet verified/i) {
                $self->stash(error => 'Please click the magic link in your email first.');
                return $self->render(template => 'auth/magic-link-error');
            }
            $self->app->log->warn("Error completing magic link: $e");
            $self->stash(error => 'This link is invalid or has expired.');
            $self->render(template => 'auth/magic-link-error');
        }
    }

    method magic_link_status {
        my $hash = $self->param('token_hash') // '';
        my $dao  = $self->dao;
        my $db   = $dao->db;

        my $token = Registry::DAO::MagicLinkToken->find_by_hash($db, $hash);

        unless ($token) {
            return $self->render(json => { status => 'not_found' });
        }

        # Expired tokens report not_found to avoid leaking token existence
        if ($token->is_expired) {
            return $self->render(json => { status => 'not_found' });
        }

        my $status = $token->consumed_at  ? 'consumed'
                   : $token->verified_at  ? 'verified'
                   :                        'pending';

        $self->render(json => { status => $status });
    }

    method magic_link_complete_by_hash {
        my $hash = $self->param('token_hash') // '';
        my $dao  = $self->dao;
        my $db   = $dao->db;

        my $token = Registry::DAO::MagicLinkToken->find_by_hash($db, $hash);

        unless ($token) {
            $self->stash(error => 'This link is invalid.');
            return $self->render(template => 'auth/magic-link-error');
        }

        if ($token->is_expired) {
            $self->stash(error => 'This link has expired. Please request a new one.');
            return $self->render(template => 'auth/magic-link-error');
        }

        try {
            $token->consume($db);

            $self->session(
                user_id          => $token->user_id,
                tenant_schema    => $self->tenant,
                authenticated_at => time(),
            );

            if ($token->purpose eq 'invite') {
                return $self->redirect_to('/auth/register-passkey');
            }

            $self->redirect_to('/');
        }
        catch ($e) {
            if ($e =~ /already consumed/i) {
                return $self->render(json => { ok => 1 });
            }
            if ($e =~ /not yet verified/i) {
                $self->stash(error => 'Please click the magic link in your email first.');
                return $self->render(template => 'auth/magic-link-error');
            }
            $self->app->log->warn("Error completing magic link by hash: $e");
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

    # Build a WebAuthn instance using the current request context to derive
    # the relying-party ID, name, and expected origin. Accepts an optional
    # $db handle to avoid creating a second connection in the calling method.
    my $build_webauthn = method ($existing_db = undef) {
        my $db     = $existing_db // $self->dao->db;
        my $tenant = Registry::DAO::Tenant->find($db, { slug => $self->tenant });

        my $rp_id   = ($tenant && $tenant->canonical_domain)
                      ? $tenant->canonical_domain
                      : $self->req->url->to_abs->host;
        my $rp_name = ($tenant && $tenant->name) ? $tenant->name : 'Registry';
        my $scheme  = $self->req->url->to_abs->scheme // 'https';
        my $origin  = "$scheme://$rp_id";

        return Registry::Auth::WebAuthn->new(
            rp_id   => $rp_id,
            rp_name => $rp_name,
            origin  => $origin,
        );
    };

    # Begin WebAuthn passkey registration for the authenticated user.
    # Generates registration options and stores the challenge in the session.
    method webauthn_register_begin {
        return unless $self->require_auth;

        my $user = $self->stash('current_user');
        my $dao  = $self->dao;
        my $db   = $dao->db;
        my $wa   = $self->$build_webauthn($db);

        # Retrieve existing passkeys so we can exclude them from registration
        my @existing = Registry::DAO::Passkey->for_user($db, $user->{id});
        my @cred_ids = map { $_->credential_id } @existing;

        my $options = $wa->generate_registration_options(
            $user->{id},
            $user->{username},
            $user->{name},
            exclude_credentials => \@cred_ids,
        );

        Registry::Auth::WebAuthn::Challenge->store($self, $options->{challenge});

        $self->render(json => $options);
    }

    # Complete WebAuthn passkey registration for the authenticated user.
    # Verifies the attestation response and stores the new passkey in the DB.
    method webauthn_register_complete {
        return unless $self->require_auth;

        my $user = $self->stash('current_user');
        my $body = $self->req->json;

        unless ($body && $body->{response}) {
            return $self->render(
                json   => { error => 'Missing attestation response' },
                status => 400,
            );
        }

        my $expected_challenge = Registry::Auth::WebAuthn::Challenge->retrieve($self);
        unless ($expected_challenge) {
            return $self->render(
                json   => { error => 'No pending registration challenge' },
                status => 400,
            );
        }

        my $dao = $self->dao;
        my $db  = $dao->db;

        my $result;
        try {
            $result = $self->$build_webauthn($db)->verify_registration_response(
                $expected_challenge,
                $body->{response}{clientDataJSON},
                $body->{response}{attestationObject},
            );
        }
        catch ($e) {
            $self->app->log->warn("WebAuthn registration verification failed: $e");
            return $self->render(
                json   => { error => 'Registration verification failed' },
                status => 400,
            );
        }

        my $passkey = Registry::DAO::Passkey->create($db, {
            user_id       => $user->{id},
            credential_id => $result->{credential_id},
            public_key    => $result->{public_key},
            sign_count    => $result->{sign_count} // 0,
        });

        $self->render(json => {
            id         => $passkey->id,
            created_at => $passkey->created_at,
        });
    }

    # Begin WebAuthn authentication ceremony (no auth required -- this IS login).
    # Accepts an email to look up the user's passkeys, then generates options.
    method webauthn_auth_begin {
        my $body  = $self->req->json // {};
        my $email = $body->{email} // '';

        unless ($email) {
            return $self->render(
                json   => { error => 'Email is required' },
                status => 400,
            );
        }

        my $dao  = $self->dao;
        my $db   = $dao->db;
        my $user = Registry::DAO::User->find($db, { email => $email });

        # Return empty allowCredentials if user not found (anti-enumeration)
        my @cred_ids;
        if ($user) {
            my @passkeys = Registry::DAO::Passkey->for_user($db, $user->id);
            @cred_ids = map { $_->credential_id } @passkeys;
        }

        my $wa      = $self->$build_webauthn($db);
        my $options = $wa->generate_authentication_options(
            allow_credentials => \@cred_ids,
        );

        Registry::Auth::WebAuthn::Challenge->store($self, $options->{challenge});

        $self->render(json => $options);
    }

    # Complete WebAuthn authentication ceremony (no auth required -- this IS login).
    # Verifies the assertion, updates the sign count, and establishes the session.
    method webauthn_auth_complete {
        my $body = $self->req->json;

        unless ($body && $body->{response}) {
            return $self->render(
                json   => { error => 'Missing assertion response' },
                status => 400,
            );
        }

        my $expected_challenge = Registry::Auth::WebAuthn::Challenge->retrieve($self);
        unless ($expected_challenge) {
            return $self->render(
                json   => { error => 'No pending authentication challenge' },
                status => 400,
            );
        }

        my $dao = $self->dao;
        my $db  = $dao->db;

        # Look up the passkey by credential ID (raw bytes from base64url)
        my $cred_id_bytes = decode_base64url($body->{id} // '');
        my ($passkey) = Registry::DAO::Passkey->find($db, { credential_id => $cred_id_bytes });

        unless ($passkey) {
            return $self->render(
                json   => { error => 'Passkey not found' },
                status => 400,
            );
        }

        my $result;
        try {
            $result = $self->$build_webauthn($db)->verify_authentication_response(
                $expected_challenge,
                $body->{response}{clientDataJSON},
                decode_base64url($body->{response}{authenticatorData} // ''),
                decode_base64url($body->{response}{signature} // ''),
                $passkey->public_key,
                $passkey->sign_count,
            );
        }
        catch ($e) {
            $self->app->log->warn("WebAuthn authentication verification failed: $e");
            return $self->render(
                json   => { error => 'Authentication verification failed' },
                status => 400,
            );
        }

        $passkey->update_sign_count($db, $result->{sign_count});

        # Establish the session -- this is the login
        $self->session(
            user_id          => $passkey->user_id,
            tenant_schema    => $self->tenant,
            authenticated_at => time(),
        );

        $self->render(json => { ok => 1 });
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
