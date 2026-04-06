# ABOUTME: Workflow step for account checking during enrollment workflows.
# ABOUTME: Handles redirecting to the auth controller for passwordless login and new account creation via magic links.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::AccountCheck :isa(Registry::DAO::WorkflowStep) {
    use Carp qw( croak );
    use Registry::DAO::User;
    use Registry::DAO::MagicLinkToken;
    use Registry::DAO::Notification;

    method process ($db, $form_data, $run = undef) {
        $run //= do { my $w = $self->workflow($db); $w->latest_run($db) };

        # Check if user selected an action
        my $action = $form_data->{action} || '';

        if ($action eq 'login') {
            # Redirect to the Auth controller which handles passkey and magic link login.
            # Password verification no longer happens here.
            return { redirect => '/auth/login' };
        }
        elsif ($action eq 'create_account') {
            # Create a new user without a password (passwordless system).
            my $user;
            try {
                $user = Registry::DAO::User->create($db, {
                    username  => $form_data->{username},
                    email     => $form_data->{email},
                    name      => $form_data->{name},
                    user_type => 'parent',
                });
            }
            catch ($e) {
                if ($e =~ /duplicate key|unique constraint|already exists/i) {
                    return {
                        errors => ['An account with that username or email already exists. Please log in instead.'],
                    };
                }
                die $e;
            }

            # Generate a magic link token and send the login email
            my ($token, $plaintext) = Registry::DAO::MagicLinkToken->generate($db, {
                user_id => $user->id,
                purpose => 'login',
            });

            my $base_url = $form_data->{_base_url} // $ENV{BASE_URL} // '';
            my $notification = Registry::DAO::Notification->create($db, {
                user_id  => $user->id,
                type     => 'magic_link_login',
                channel  => 'email',
                subject  => 'Sign in to Registry',
                message  => "Magic link login for " . $form_data->{email},
                metadata => {
                    tenant_name      => 'Registry',
                    magic_link_url   => "$base_url/auth/magic/$plaintext",
                    expires_in_hours => 24,
                },
            });
            $notification->send($db);

            return { redirect => '/auth/magic-link-sent', user_id => $user->id };
        }
        elsif ($action eq 'continue_logged_in') {
            # User is already logged in (returning from continuation or already had session)
            my $user_id = $run->data->{user_id};

            if ($user_id) {
                # Verify user still exists
                my $user = Registry::DAO::User->find($db, { id => $user_id });

                if ($user) {
                    # Store/update user info in run data
                    $run->update_data($db, {
                        user_id    => $user->id,
                        user_name  => $user->name,
                        user_email => $user->email,
                    });

                    # Move to next step
                    my $next_step = $self->next_step($db);
                    return { next_step => $next_step ? $next_step->slug : undef };
                }
            }

            # No valid user - stay on this step
            return { stay => 1 };
        }
        else {
            # First visit or returning from continuation

            # Check if we're returning from user creation
            if ($run->has_continuation) {
                my $continuation = $run->continuation($db);
                my $cont_data = $continuation->data;

                # Check if user was created
                if ($cont_data->{user_id}) {
                    # User was created - store info and continue
                    $run->update_data($db, {
                        user_id    => $cont_data->{user_id},
                        user_name  => $cont_data->{user_name},
                        user_email => $cont_data->{user_email},
                        # Restore enrollment data
                        %{$cont_data->{enrollment_data} || {}}
                    });

                    # Mark continuation as complete
                    # TODO: Implement proper continuation completion

                    # Move to next step
                    my $next_step = $self->next_step($db);
                    return { next_step => $next_step ? $next_step->slug : undef };
                }
            }

            # Check if user is already logged in (session)
            # This would normally check the controller's session
            # For now, we'll stay on this step to show options
            return { stay => 1 };
        }
    }

    method validate ($db, $form_data) {
        my $action = $form_data->{action} // '';

        if ($action eq 'create_account') {
            my @errors;
            push @errors, 'Email is required'    unless $form_data->{email};
            push @errors, 'Username is required'  unless $form_data->{username};
            return { errors => \@errors } if @errors;
        }

        return undef;
    }
}