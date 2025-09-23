use 5.40.2;
use experimental 'signatures', 'try', 'builtin';
use Object::Pad;

class Registry::DAO::WorkflowSteps::InstallmentPayment :isa(Registry::DAO::WorkflowStep) {

use Registry::DAO::Payment;
use Registry::DAO::PaymentSchedule;
use Registry::DAO::PricingPlan;
use Registry::DAO::Event;  # Contains Session class
use Registry::DAO::User;
use Mojo::JSON qw(encode_json);
use DateTime;

method process ($db, $form_data) {
    my $workflow = $self->workflow($db);
    my $run = $workflow->latest_run($db);

    # Handle Stripe webhook callback for first payment
    if ($form_data->{payment_intent_id}) {
        return $self->handle_payment_callback($db, $run, $form_data);
    }

    # Handle installment plan selection
    if ($form_data->{selected_plan_id}) {
        return $self->process_plan_selection($db, $run, $form_data);
    }

    # Initial payment page load - show plan options
    return {
        next_step => $self->id,
        data => $self->prepare_payment_options($db, $run)
    };
}

method prepare_payment_options ($db, $run) {
    # Calculate total and get available pricing plans
    my $enrollment_data = {
        children => $run->data->{children} || [],
        session_selections => $run->data->{session_selections} || {},
    };

    my $payment_info = Registry::DAO::Payment->calculate_enrollment_total($db, $enrollment_data);

    # Get available pricing plans with installment options
    my $installment_plans = $self->get_installment_plans($db, $enrollment_data);

    return {
        total => $payment_info->{total},
        items => $payment_info->{items},
        payment_options => {
            full_payment => {
                type => 'full',
                amount => $payment_info->{total},
                description => 'Pay in full',
            },
            installment_plans => $installment_plans,
        },
        stripe_publishable_key => $ENV{STRIPE_PUBLISHABLE_KEY},
    };
}

method get_installment_plans ($db, $enrollment_data) {
    my @plans;

    # Get pricing plans from selected sessions
    my $session_selections = $enrollment_data->{session_selections} || {};
    my %unique_sessions;

    for my $child (@{$enrollment_data->{children}}) {
        my $child_key = $child->{id} || 0;
        my $session_id = $session_selections->{$child_key} || $session_selections->{all};
        $unique_sessions{$session_id} = 1 if $session_id;
    }

    for my $session_id (keys %unique_sessions) {
        my $session = Registry::DAO::Session->find($db, { id => $session_id });
        next unless $session;

        my $pricing_plans = $session->pricing_plans($db);
        for my $plan (@$pricing_plans) {
            next unless $plan->installments_allowed;

            my $installment_count = $plan->installment_count;
            next unless $installment_count > 1;

            # Calculate installment amount based on total
            my $payment_info = Registry::DAO::Payment->calculate_enrollment_total($db, $enrollment_data);
            my $installment_amount = sprintf("%.2f", $payment_info->{total} / $installment_count);

            push @plans, {
                id => $plan->id,
                name => $plan->plan_name,
                installment_count => $installment_count,
                installment_amount => $installment_amount,
                total_amount => $payment_info->{total},
                frequency => 'monthly', # Default frequency
                description => "Pay in $installment_count installments of \$$installment_amount",
            };
        }
    }

    return \@plans;
}

method process_plan_selection ($db, $run, $form_data) {
    my $selected_plan_id = $form_data->{selected_plan_id};
    my $payment_type = $form_data->{payment_type} || 'full';

    if ($payment_type eq 'full') {
        # Redirect to regular payment processing
        return $self->process_full_payment($db, $run, $form_data);
    }

    # Handle installment payment
    my $pricing_plan = Registry::DAO::PricingPlan->find($db, { id => $selected_plan_id });
    die "Pricing plan not found" unless $pricing_plan;
    die "Selected plan does not allow installments" unless $pricing_plan->installments_allowed;

    return $self->create_installment_payment($db, $run, $form_data, $pricing_plan);
}

method process_full_payment ($db, $run, $form_data) {
    # Use the existing Payment workflow step logic for full payments
    # This delegates to the regular payment processing

    my $user_id = $run->data->{user_id} or die "No user_id in workflow data";
    my $user = Registry::DAO::User->find($db, { id => $user_id });

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
            payment_type => 'full',
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
            description => 'Program Enrollment - Full Payment',
            receipt_email => $user->email,
        });
    } catch ($error) {
        return {
            next_step => $self->id,
            errors => ["Payment processing error: $error"],
            data => $self->prepare_payment_options($db, $run),
        };
    };

    # Store payment info in workflow data
    $run->update_data($db, {
        payment_id => $payment->id,
        payment_type => 'full',
    });

    return {
        next_step => $self->id,
        data => {
            payment_type => 'full',
            payment_id => $payment->id,
            client_secret => $intent_data->{client_secret},
            show_stripe_form => 1,
            total => $payment_info->{total},
        }
    };
}

method create_installment_payment ($db, $run, $form_data, $pricing_plan) {
    my $user_id = $run->data->{user_id} or die "No user_id in workflow data";
    my $user = Registry::DAO::User->find($db, { id => $user_id });

    my $enrollment_data = {
        children => $run->data->{children} || [],
        session_selections => $run->data->{session_selections} || {},
    };

    my $payment_info = Registry::DAO::Payment->calculate_enrollment_total($db, $enrollment_data);

    # Create first payment for immediate processing
    my $installment_amount = sprintf("%.2f", $payment_info->{total} / $pricing_plan->installment_count);

    my $first_payment = Registry::DAO::Payment->create($db, {
        user_id => $user_id,
        amount => $installment_amount,
        metadata => {
            workflow_id => $run->workflow_id,
            workflow_run_id => $run->id,
            enrollment_data => $enrollment_data,
            payment_type => 'installment_first',
            total_amount => $payment_info->{total},
            installment_count => $pricing_plan->installment_count,
            installment_number => 1,
        }
    });

    # Add line items for first payment
    for my $item (@{$payment_info->{items}}) {
        $first_payment->add_line_item($db, {
            %$item,
            amount => sprintf("%.2f", $item->{amount} / $pricing_plan->installment_count),
            metadata => {
                %{$item->{metadata} || {}},
                installment_portion => 1,
                total_installments => $pricing_plan->installment_count,
            }
        });
    }

    # Create Stripe payment intent for first payment
    my $intent_data;
    try {
        $intent_data = $first_payment->create_payment_intent($db, {
            description => "Program Enrollment - Installment 1 of " . $pricing_plan->installment_count,
            receipt_email => $user->email,
        });
    } catch ($error) {
        return {
            next_step => $self->id,
            errors => ["Payment processing error: $error"],
            data => $self->prepare_payment_options($db, $run),
        };
    };

    # Store payment and plan info in workflow data
    $run->update_data($db, {
        first_payment_id => $first_payment->id,
        payment_type => 'installment',
        pricing_plan_id => $pricing_plan->id,
        total_amount => $payment_info->{total},
        installment_count => $pricing_plan->installment_count,
        installment_amount => $installment_amount,
    });

    return {
        next_step => $self->id,
        data => {
            payment_type => 'installment',
            payment_id => $first_payment->id,
            client_secret => $intent_data->{client_secret},
            show_stripe_form => 1,
            installment_info => {
                current_payment => 1,
                total_installments => $pricing_plan->installment_count,
                installment_amount => $installment_amount,
                total_amount => $payment_info->{total},
            },
        }
    };
}

method handle_payment_callback ($db, $run, $form_data) {
    my $payment_type = $run->data->{payment_type} || 'full';

    if ($payment_type eq 'full') {
        return $self->handle_full_payment_callback($db, $run, $form_data);
    } else {
        return $self->handle_installment_payment_callback($db, $run, $form_data);
    }
}

method handle_full_payment_callback ($db, $run, $form_data) {
    my $payment_id = $run->data->{payment_id} or die "No payment_id in workflow data";

    my $payment = Registry::DAO::Payment->new(id => $payment_id)->load($db);
    my $result = $payment->process_payment($db, $form_data->{payment_intent_id});

    if ($result->{success}) {
        # Create enrollments
        $self->create_enrollments($db, $run, $payment);
        return { next_step => 'complete' };
    } elsif ($result->{processing}) {
        return {
            next_step => $self->id,
            data => { processing => 1, message => 'Payment is being processed. Please wait...' }
        };
    } else {
        return {
            next_step => $self->id,
            errors => [$result->{error}],
            data => $self->prepare_payment_options($db, $run),
        };
    }
}

method handle_installment_payment_callback ($db, $run, $form_data) {
    my $first_payment_id = $run->data->{first_payment_id} or die "No first_payment_id in workflow data";

    my $first_payment = Registry::DAO::Payment->new(id => $first_payment_id)->load($db);
    my $result = $first_payment->process_payment($db, $form_data->{payment_intent_id});

    if ($result->{success}) {
        # Create enrollments first
        my @enrollments = $self->create_enrollments($db, $run, $first_payment);

        # Create payment schedule for remaining installments
        my $schedule = Registry::DAO::PaymentSchedule->create_for_enrollment($db, {
            enrollment_id => $enrollments[0]->{id}, # Use first enrollment as reference
            pricing_plan_id => $run->data->{pricing_plan_id},
            total_amount => $run->data->{total_amount},
            installment_count => $run->data->{installment_count},
            first_payment_date => DateTime->now->add(months => 1)->ymd, # Next payment in 1 month
        });

        # Store schedule ID for future reference
        $run->update_data($db, { payment_schedule_id => $schedule->id });

        return { next_step => 'complete' };
    } elsif ($result->{processing}) {
        return {
            next_step => $self->id,
            data => {
                processing => 1,
                message => 'First installment payment is being processed. Please wait...',
                payment_type => 'installment',
            }
        };
    } else {
        return {
            next_step => $self->id,
            errors => [$result->{error}],
            data => $self->prepare_payment_options($db, $run),
        };
    }
}

method create_enrollments ($db, $run, $payment) {
    my @enrollments;
    my $children = $run->data->{children} || [];
    my $selections = $run->data->{session_selections} || {};

    for my $child (@$children) {
        my $child_key = $child->{id} || 0;
        my $session_id = $selections->{$child_key} || $selections->{all};

        next unless $session_id;

        # Create enrollment
        my $enrollment_data = {
            session_id => $session_id,
            student_id => $run->data->{user_id},
            family_member_id => $child->{id},
            status => 'active',
            payment_id => $payment->id,
            metadata => encode_json({
                child_name => "$child->{first_name} $child->{last_name}",
                enrolled_via => 'installment_workflow',
                payment_type => $run->data->{payment_type},
            }),
        };

        my $enrollment = $db->insert('enrollments', $enrollment_data, { returning => '*' })->hash;
        push @enrollments, $enrollment;

        # Link to payment item
        $db->update('registry.payment_items',
            { enrollment_id => $enrollment->{id} },
            {
                payment_id => $payment->id,
                'metadata->child_id' => $child->{id},
                'metadata->session_id' => $session_id,
            }
        );
    }

    return @enrollments;
}

method template { 'summer-camp-registration/installment-payment' }

}