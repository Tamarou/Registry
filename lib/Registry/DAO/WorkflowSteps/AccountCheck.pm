# ABOUTME: Workflow step for account checking during enrollment workflows.
# ABOUTME: Handles redirecting to the auth controller for passwordless login and new account creation via magic links.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::AccountCheck :isa(Registry::DAO::WorkflowStep) {
    use Carp qw( croak );
    use Registry::Email::Template;
    use Email::Simple;
    use Email::Sender::Simple qw(sendmail);

    method process ($db, $form_data) {
        my $workflow = $self->workflow($db);
        my $run = $workflow->latest_run($db);

        # Check if user selected an action
        my $action = $form_data->{action} || '';

        if ($action eq 'login') {
            # Redirect to the Auth controller which handles passkey and magic link login.
            # Password verification no longer happens here.
            return { redirect => '/auth/login' };
        }
        elsif ($action eq 'create_account') {
            # Create a new user without a password (passwordless system).
            require Registry::DAO::User;
            require Registry::DAO::MagicLinkToken;

            my $user = Registry::DAO::User->create($db, {
                username  => $form_data->{username},
                email     => $form_data->{email},
                name      => $form_data->{name},
                user_type => $form_data->{user_type} || 'parent',
            });

            # Generate a magic link token and send the login email
            my ($token, $plaintext) = Registry::DAO::MagicLinkToken->generate($db, {
                user_id => $user->id,
                purpose => 'login',
            });

            # Send the magic link email so the user can authenticate
            my $rendered = Registry::Email::Template->render(
                'magic_link_login',
                tenant_name      => 'Registry',
                magic_link_url   => "/auth/magic/$plaintext",
                expires_in_hours => 24,
            );

            my $mail = Email::Simple->create(
                header => [
                    To      => $form_data->{email},
                    From    => $ENV{NOTIFICATION_FROM_EMAIL} || 'noreply@registry.example.com',
                    Subject => 'Sign in to Registry',
                ],
                body => $rendered->{text},
            );
            sendmail($mail);

            return { redirect => '/auth/magic-link-sent', user_id => $user->id };
        }
        elsif ($action eq 'continue_logged_in') {
            # User is already logged in (returning from continuation or already had session)
            my $user_id = $form_data->{user_id} || $run->data->{user_id};

            if ($user_id) {
                # Verify user still exists
                require Registry::DAO::User;
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