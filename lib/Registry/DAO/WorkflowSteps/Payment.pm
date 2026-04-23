use 5.42.0;

use Object::Pad;

class Registry::DAO::WorkflowSteps::Payment :isa(Registry::DAO::WorkflowStep) {

use Registry::DAO::Payment;
use Registry::DAO::Event;  # Contains Session class
use Registry::DAO::User;
use Registry::DAO::Project;
use Registry::DAO::Location;
use Registry::DAO::Notification;
use Mojo::JSON qw(encode_json);

method process ($db, $form_data, $run = undef) {
    $run //= do { my $w = $self->workflow($db); $w->latest_run($db) };

    # Handle Stripe webhook callback
    if ($form_data->{payment_intent_id}) {
        return $self->handle_payment_callback($db, $run, $form_data);
    }

    # Any non-callback interaction (new terms agreement, page view via
    # process) means the user moved past a prior retry. Clear stale
    # state so an unrelated navigation can't resurrect a dead intent.
    if ($run->data->{payment_retry_state}) {
        $run->update_data($db, { payment_retry_state => undef });
    }

    # Demo mode: when STRIPE_SECRET_KEY is not set, accept terms agreement
    # and create enrollments directly without Stripe processing.
    if ($form_data->{agreeTerms} && !$ENV{STRIPE_SECRET_KEY}) {
        return $self->create_demo_enrollments($db, $run, $form_data);
    }

    # Initial payment page load or form submission
    if ($form_data->{agreeTerms}) {
        return $self->create_payment($db, $run, $form_data);
    }

    # Just show the payment page
    return {
        next_step => $self->id,
        data => $self->prepare_payment_data($db, $run)
    };
}

method prepare_payment_data ($db, $run) {
    # Calculate total and prepare line items
    my $enrollment_data = {
        children => $run->data->{children} || [],
        session_selections => $run->data->{session_selections} || {},
    };

    my $payment_info = Registry::DAO::Payment->calculate_enrollment_total($db, $enrollment_data);

    return {
        total => $payment_info->{total},
        items => $payment_info->{items},
        stripe_publishable_key => $ENV{STRIPE_PUBLISHABLE_KEY},
    };
}

# Surface the summary data (and any pending retry state) the template
# needs. Without this override, stash('step_data') is empty on re-entry
# after a flash-redirect, which is how the no-JS error path works.
method prepare_template_data ($db, $run, $params = {}) {
    my $step_data  = $self->prepare_payment_data($db, $run);
    my $retry_state = $run->data->{payment_retry_state} || {};

    return {
        step_data => {
            %$step_data,
            %$retry_state,
        },
    };
}

method create_payment ($db, $run, $form_data) {
    my $user_id = $run->data->{user_id} or die "No user_id in workflow data";
    
    # Get user for email
    my $user = Registry::DAO::User->find($db, { id => $user_id });
    
    # Calculate total
    my $enrollment_data = {
        children => $run->data->{children} || [],
        session_selections => $run->data->{session_selections} || {},
    };
    
    my $payment_info = Registry::DAO::Payment->calculate_enrollment_total($db, $enrollment_data);
    
    # Create payment record
    my $payment = Registry::DAO::Payment->create($db, {
        user_id => $user_id,
        amount => $payment_info->{total},
        metadata => {
            workflow_id => $run->workflow_id,
            workflow_run_id => $run->id,
            enrollment_data => $enrollment_data,
        }
    });
    
    # Add line items
    for my $item (@{$payment_info->{items}}) {
        $payment->add_line_item($db, $item);
    }
    
    # Create Stripe payment intent
    my $intent_data;
    try {
        $intent_data = $payment->create_payment_intent($db, {
            description => 'Program Enrollment',
            receipt_email => $user->email,
        });
    } catch ($error) {
        return {
            next_step => $self->id,
            errors => ["Payment processing error: $error"],
            data => $self->prepare_payment_data($db, $run),
        };
    };
    
    # Store payment ID in workflow data
    $run->update_data($db, { payment_id => $payment->id });
    
    return {
        next_step => $self->id,
        data => {
            %{$self->prepare_payment_data($db, $run)},
            payment_id => $payment->id,
            client_secret => $intent_data->{client_secret},
            show_stripe_form => 1,
        }
    };
}

method handle_payment_callback ($db, $run, $form_data) {
    my $payment_id = $run->data->{payment_id} or die "No payment_id in workflow data";

    my $payment = Registry::DAO::Payment->find($db, { id => $payment_id });
    die "Payment $payment_id not found" unless $payment;

    # Process the payment
    my $result = $payment->process_payment($db, $form_data->{payment_intent_id});

    if ($result->{success}) {
        # Create enrollments from the enrollment_items stored by MultiChildSessionSelection
        require Registry::DAO::Enrollment;
        my $enrollment_items = $run->data->{enrollment_items} || [];
        my $user_id = $run->data->{user_id};

        for my $item (@$enrollment_items) {
            my $enrollment = Registry::DAO::Enrollment->create($db, {
                session_id       => $item->{session_id},
                family_member_id => $item->{child_id},
                parent_id        => $user_id,
                status           => 'active',
                payment_id       => $payment->id,
            });
        }

        $self->_queue_enrollment_confirmations(
            $db, $user_id, $enrollment_items,
        );

        # Payment successful, clear any lingering retry state and
        # move to completion.
        $run->update_data($db, { payment_retry_state => undef });
        return { next_step => 'complete' };
    } elsif ($result->{processing}) {
        # Payment still processing
        return {
            next_step => $self->id,
            data => {
                %{$self->prepare_payment_data($db, $run)},
                processing => 1,
                message => 'Payment is being processed. Please wait...',
            }
        };
    } else {
        # Payment failed. Re-issue a fresh Stripe PaymentIntent so the
        # parent can retry with a different card immediately instead of
        # being dumped back at the terms-agreement page. The Payment
        # record is reused so we don't orphan it.
        my $user = Registry::DAO::User->find($db, { id => $run->data->{user_id} });
        my $retry_intent;
        try {
            $retry_intent = $payment->create_payment_intent($db, {
                description   => 'Program Enrollment (retry)',
                receipt_email => $user ? $user->email : undef,
            });
        }
        catch ($retry_err) {
            # Couldn't even create a retry intent -- surface both
            # failures and drop back to the non-retry state. Also
            # clear any stale retry state.
            $run->update_data($db, { payment_retry_state => undef });
            return {
                next_step => $self->id,
                errors    => [
                    $result->{error},
                    "Retry unavailable: $retry_err",
                ],
                data => $self->prepare_payment_data($db, $run),
            };
        }

        # Persist retry state so prepare_template_data can surface it
        # on the subsequent GET (flash-redirect path).
        my %retry_state = (
            payment_id       => $payment->id,
            client_secret    => $retry_intent->{client_secret},
            show_stripe_form => 1,
            retry            => 1,
        );
        $run->update_data($db, { payment_retry_state => \%retry_state });

        return {
            next_step => $self->id,
            errors    => [$result->{error}],
            data      => {
                %{$self->prepare_payment_data($db, $run)},
                %retry_state,
            },
        };
    }
}

method create_demo_enrollments ($db, $run, $form_data) {
    my $user_id = $run->data->{user_id} or die "No user_id in workflow data";
    my $enrollment_items = $run->data->{enrollment_items} || [];

    require Registry::DAO::Enrollment;
    for my $item (@$enrollment_items) {
        Registry::DAO::Enrollment->create($db, {
            session_id       => $item->{session_id},
            family_member_id => $item->{child_id},
            parent_id        => $user_id,
            status           => 'active',
        });
    }

    $self->_queue_enrollment_confirmations($db, $user_id, $enrollment_items);

    return { next_step => 'complete' };
}

# Queue one enrollment_confirmation notification per enrollment so the
# parent receives a receipt/confirmation email. The worker picks these
# up via the existing Notification sender pipeline, which routes through
# Postmark in production (see Registry::DAO::Notification).
method _queue_enrollment_confirmations ($db, $user_id, $enrollment_items) {
    for my $item (@$enrollment_items) {
        my $session_id = $item->{session_id} or next;
        my $session = Registry::DAO::Session->find($db, { id => $session_id });
        next unless $session;

        # Pull the first associated event to surface program/location.
        my ($event) = $session->events($db);

        my $project_name;
        my $location_name;
        if ($event) {
            if (my $project_id = $event->project_id) {
                if (my $project = Registry::DAO::Project->find($db, { id => $project_id })) {
                    $project_name = $project->name;
                }
            }
            if (my $location_id = $event->location_id) {
                if (my $location = Registry::DAO::Location->find($db, { id => $location_id })) {
                    $location_name = $location->name;
                }
            }
        }

        Registry::DAO::Notification->create($db, {
            user_id  => $user_id,
            type     => 'enrollment_confirmation',
            channel  => 'email',
            subject  => 'Enrollment confirmed',
            message  => 'Your enrollment has been confirmed.',
            metadata => {
                session_id    => $session_id,
                event_name    => $session->name,
                start_date    => $session->start_date,
                project_name  => $project_name,
                location_name => $location_name,
                child_id      => $item->{child_id},
            },
        });
    }
}

method template { 'summer-camp-registration/payment' }

}