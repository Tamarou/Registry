use 5.42.0;

use Object::Pad;

class Registry::DAO::WorkflowSteps::Payment :isa(Registry::DAO::WorkflowStep) {

use Registry::DAO::Payment;
use Registry::DAO::Event;  # Contains Session class
use Registry::DAO::User;
use Registry::DAO::Location;
use Registry::DAO::Notification;
use Registry::DAO::Tenant;
use Mojo::JSON qw(encode_json);
use Mojo::Promise;

# The two Stripe-touching branches (create_payment, handle_payment_callback)
# return a Mojo::Promise; the free-enrollment and page-view branches return a
# plain hashref. WorkflowRun::process accepts either. Blocking on the Stripe
# call instead is not an option in the web path: Mojo::Promise::wait returns
# immediately once its loop is already running, which under the daemon turns
# every paid enrollment into a "Payment processing error".
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

    if ($form_data->{agreeTerms}) {
        my $info = Registry::DAO::Payment->calculate_enrollment_total($db, {
            children           => $run->data->{children}           || [],
            session_selections => $run->data->{session_selections} || {},
        });

        # Whether payment is taken is a function of the program's pricing, not
        # the environment. A $0 total enrolls without the gateway regardless of
        # whether Stripe is configured. Demo/dev (no Stripe key) also skips it.
        # Anything with a balance due goes through Stripe.
        if (($info->{total} // 0) == 0 || !$ENV{STRIPE_SECRET_KEY}) {
            return $self->create_demo_enrollments($db, $run, $form_data);
        }

        return $self->create_payment($db, $run, $form_data);
    }

    # Just show the payment page
    return {
        next_step => $self->id,
        data => $self->_render_data($db, $run)
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

# The value for a step result's `data` key. Controller::Workflows splats that
# hash flat into the stash, but this step's template reads everything out of
# stash('step_data') -- so anything returned unwrapped is silently dropped on
# the floor, card form included. Same shape prepare_template_data returns, so
# both entry points (POST render and flash-redirect GET) agree.
method _render_data ($db, $run, %extra) {
    return { step_data => { %{ $self->prepare_payment_data($db, $run) }, %extra } };
}

# The run's payment_id is bound straight into a WHERE clause, so it must be a
# plain scalar. Run data is merged from request params, and a bracketed name
# (payment_id[!=]=<uuid>) expands to { '!=' => <uuid> } -- which SQL::Abstract
# renders as an operator, turning `WHERE id = ?` into `WHERE id != ?` and
# pointing the reuse UPDATE/DELETE at every other payment in the tenant. There
# is no sanitised reading of a client-chosen operator, so refuse it outright.
method _run_payment_id ($run) {
    my $payment_id = $run->data->{payment_id};
    die "Invalid payment_id in workflow data" if ref $payment_id;
    return $payment_id;
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

    # Paid enrollment requires a ready Stripe Connect account: tuition must
    # settle into the tenant's own account (Registry is not the merchant of
    # record). Free enrollment has no charge and is exempt.
    #
    # Tenant rows are platform data living ONLY in registry.tenants. $db here
    # is tenant-scoped, and clone_schema gives every tenant schema an empty
    # shadow `tenants` table, so an unqualified Tenant->find would always
    # return undef -- the lookup must be registry-qualified (same convention
    # as Tenant::slug_exists).
    my $tenant_slug = $run->data->{__tenant_slug};
    if ($payment_info->{total} > 0) {
        # tenants has no jsonb columns; plain ->hash is sufficient (no ->expand).
        my $row = $tenant_slug
            ? $db->query('SELECT * FROM registry.tenants WHERE slug = ?', $tenant_slug)->hash
            : undef;
        my $tenant = $row ? Registry::DAO::Tenant->new(%$row) : undef;
        unless ($tenant && $tenant->stripe_connect_ready) {
            return Mojo::Promise->resolve({
                next_step => $self->id,
                errors    => ['Online payment is not yet available for this organization. '
                            . 'Please contact the program organizer to complete enrollment.'],
                data      => $self->_render_data($db, $run),
            });
        }
    }

    # Reuse existing payment row for this run if it exists and is not yet
    # completed. A double-submit of the same agreeTerms form must not create
    # a second payment row or a second Stripe charge -- the stable
    # idempotency_token on the existing row ensures Stripe deduplicates too.
    # ponytail: reuse check; completed payments start a new row (second purchase)
    my $existing_payment_id = $self->_run_payment_id($run);
    my $payment;
    # Cancelling the superseded intent has to finish before the replacement is
    # minted, so it is threaded through the chain rather than fired and
    # forgotten -- otherwise two confirmable intents can exist at once.
    my $supersede = Mojo::Promise->resolve;
    if ($existing_payment_id) {
        my $existing = Registry::DAO::Payment->find($db, { id => $existing_payment_id });
        if ($existing && $existing->status ne 'completed') {
            # Refresh amount and enrollment snapshot in DB; preserve idempotency_token
            my $raw_db = ($db isa Registry::DAO) ? $db->db : $db;
            my $updated_meta = {
                %{$existing->metadata},
                enrollment_data  => $enrollment_data,
                enrollment_items => $run->data->{enrollment_items} || [],
            };
            $raw_db->update('payments', {
                amount_cents => $payment_info->{total},
                metadata     => { -json => $updated_meta },
            }, { id => $existing_payment_id });
            # Remove stale line items; fresh ones added below
            $raw_db->delete('payment_items', { payment_id => $existing_payment_id });
            # Reload to pick up the updated amount in the in-memory object
            $payment = Registry::DAO::Payment->find($db, { id => $existing_payment_id });

            # A changed cart must become a NEW Stripe charge: replaying the
            # old idempotency key with a different amount is a guaranteed
            # Stripe idempotency_error (same key, different body), which
            # would dead-end the run. Rotate the key and cancel the
            # superseded intent so at most one confirmable PaymentIntent
            # exists for this payment row. An identical resubmit keeps the
            # token, so Stripe replays the same intent (at most one charge).
            if ($existing->amount_cents != $payment_info->{total}) {
                $payment->rotate_idempotency_token($db);
                if (my $old_intent = $payment->stripe_payment_intent_id) {
                    # Best-effort: an already-settled or already-canceled
                    # intent makes this a no-op error we can ignore.
                    $supersede = $payment->stripe_client
                        ->cancel_payment_intent_async($old_intent)
                        ->catch(sub ($cancel_err) { });
                }
            }
        }
    }

    unless ($payment) {
        # First submit for this run: create the payment record
        $payment = Registry::DAO::Payment->create($db, {
            user_id => $user_id,
            amount_cents => $payment_info->{total},
            metadata => {
                workflow_id => $run->workflow_id,
                workflow_run_id => $run->id,
                enrollment_data => $enrollment_data,
                # Snapshot what finalization needs so the payment_intent.succeeded
                # webhook can complete the enrollment without the workflow run:
                # the resolved (session, child) pairs and the tenant schema they
                # belong to.
                enrollment_items => $run->data->{enrollment_items} || [],
                tenant_slug => $run->data->{__tenant_slug},
            }
        });
    }

    # Link the row to the run BEFORE the intent call: if intent creation dies
    # (Stripe outage, config error), the next submit must still find and reuse
    # this row instead of orphaning it and minting a second token.
    $run->update_data($db, { payment_id => $payment->id });

    # Add line items (fresh for both new and reused payments)
    for my $item (@{$payment_info->{items}}) {
        $payment->add_line_item($db, $item);
    }

    # Create Stripe payment intent
    return $supersede->then(sub {
        $payment->create_payment_intent_async($db, {
            description => 'Program Enrollment',
            receipt_email => $user->email,
        });
    })->then(sub ($intent_data) {
        return {
            next_step => $self->id,
            data => $self->_render_data($db, $run,
                payment_id => $payment->id,
                client_secret => $intent_data->{client_secret},
                show_stripe_form => 1,
            ),
        };
    }, sub ($error) {
        return {
            next_step => $self->id,
            errors => ["Payment processing error: $error"],
            data => $self->_render_data($db, $run),
        };
    });
}

method handle_payment_callback ($db, $run, $form_data) {
    my $payment_id = $self->_run_payment_id($run) or die "No payment_id in workflow data";

    my $payment = Registry::DAO::Payment->find($db, { id => $payment_id });
    die "Payment $payment_id not found" unless $payment;

    # Process the payment
    return $payment->process_payment_async($db, $form_data->{payment_intent_id})
        ->then(sub ($result) { $self->_settle_callback($db, $run, $payment, $result) });
}

method _settle_callback ($db, $run, $payment, $result) {
    # already_completed is a superseded intent landing on a row Stripe has
    # already captured -- the back button after a 3DS retry. The money is in,
    # so it settles exactly like success: finalize_enrollment is idempotent per
    # payment, and routing it anywhere else would show an error (or a live card
    # form) to a parent who has already paid.
    if ($result->{success} || $result->{already_completed}) {
        # Idempotently create enrollments and queue confirmation emails. The
        # same finalizer runs from the payment_intent.succeeded webhook, so a
        # card finalized off-site (3DS/redirect) and the parent returning to
        # this page can both fire without producing duplicate enrollments or
        # emails.
        $payment->finalize_enrollment($db);

        # Payment successful, clear any lingering retry state and
        # move to completion.
        $run->update_data($db, { payment_retry_state => undef });
        return { next_step => 'complete' };
    } elsif ($result->{processing}) {
        # Payment still processing
        return {
            next_step => $self->id,
            data => $self->_render_data($db, $run,
                processing => 1,
                message => 'Payment is being processed. Please wait...',
            ),
        };
    } else {
        my $intent_status = $result->{intent_status} // '';

        # Customer is mid-authentication (e.g. 3DS): the intent is still live
        # and confirmable. Minting a replacement here would leave TWO live
        # PaymentIntents (a double-charge window), so surface an in-progress
        # state instead and let the webhook or a later callback settle it.
        if ($intent_status eq 'requires_action' || $intent_status eq 'requires_confirmation') {
            return {
                next_step => $self->id,
                data => $self->_render_data($db, $run,
                    processing => 1,
                    message => 'Payment requires additional verification. '
                             . 'Please complete the authentication step.',
                ),
            };
        }

        # Only a true terminal state gets a fresh intent: a decline
        # (requires_payment_method) or a canceled intent. Anything else --
        # transport errors, unknown states, ownership rejections -- surfaces
        # the failure without minting a replacement charge.
        unless ($intent_status eq 'requires_payment_method' || $intent_status eq 'canceled') {
            $run->update_data($db, { payment_retry_state => undef });
            return {
                next_step => $self->id,
                errors    => [ $result->{error} ],
                data      => $self->_render_data($db, $run),
            };
        }

        # Payment declined. Re-issue a fresh Stripe PaymentIntent so the
        # parent can retry with a different card immediately instead of
        # being dumped back at the terms-agreement page. The Payment
        # record is reused so we don't orphan it. Rotate the idempotency
        # token first: the retry must be a genuinely new Stripe charge,
        # not a replay of the declined one. Cancel the superseded intent
        # (best-effort) so at most one confirmable PaymentIntent exists;
        # a declined intent is still re-confirmable at Stripe otherwise.
        my $user = Registry::DAO::User->find($db, { id => $run->data->{user_id} });

        my $cancel = Mojo::Promise->resolve;
        if (my $old_intent = $payment->stripe_payment_intent_id) {
            $cancel = $payment->stripe_client->cancel_payment_intent_async($old_intent)
                ->catch(sub ($cancel_err) { });   # already settled/canceled is fine
        }

        return $cancel->then(sub {
            $payment->rotate_idempotency_token($db);
            $payment->create_payment_intent_async($db, {
                description   => 'Program Enrollment (retry)',
                receipt_email => $user ? $user->email : undef,
            });
        })->then(sub ($retry_intent) {
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
                data      => $self->_render_data($db, $run, %retry_state),
            };
        }, sub ($retry_err) {
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
                data => $self->_render_data($db, $run),
            };
        });
    }
}

method create_demo_enrollments ($db, $run, $form_data) {
    my $user_id = $run->data->{user_id} or die "No user_id in workflow data";

    require Registry::DAO::Enrollment;
    Registry::DAO::Enrollment->enroll_children(
        $db, $user_id, $run->data->{enrollment_items} || []
    );

    return { next_step => 'complete' };
}

method template { 'summer-camp-registration/payment' }

}