package Registry::DAO::WorkflowSteps::Payment;
use 5.40.2;
use warnings;
use experimental 'signatures', 'try', 'builtin';

use Object::Pad;
class Registry::DAO::WorkflowSteps::Payment :isa(Registry::DAO::WorkflowStep);

use Registry::DAO::Payment;
use Registry::DAO::Event;  # Contains Session class
use Registry::DAO::User;
use Mojo::JSON qw(encode_json);

method process ($db, $form_data) {
    my $workflow = $self->workflow($db);
    my $run = $workflow->latest_run($db);
    
    # Handle Stripe webhook callback
    if ($form_data->{payment_intent_id}) {
        return $self->handle_payment_callback($db, $run, $form_data);
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

method create_payment ($db, $run, $form_data) {
    my $user_id = $run->data->{user_id} or die "No user_id in workflow data";
    
    # Get user for email
    my $user = Registry::DAO::User->new(id => $user_id)->load($db);
    
    # Calculate total
    my $enrollment_data = {
        children => $run->data->{children} || [],
        session_selections => $run->data->{session_selections} || {},
    };
    
    my $payment_info = Registry::DAO::Payment->calculate_enrollment_total($db, $enrollment_data);
    
    # Create payment record
    my $payment = Registry::DAO::Payment->new(
        user_id => $user_id,
        amount => $payment_info->{total},
        metadata => {
            workflow_id => $workflow->id,
            workflow_run_id => $run->id,
            enrollment_data => $enrollment_data,
        }
    )->save($db);
    
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
    $run->data->{payment_id} = $payment->id;
    $run->save($db);
    
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
    
    my $payment = Registry::DAO::Payment->new(id => $payment_id)->load($db);
    
    # Process the payment
    my $result = $payment->process_payment($db, $form_data->{payment_intent_id});
    
    if ($result->{success}) {
        # Create enrollments for each child
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
                    enrolled_via => 'enhanced_workflow',
                }),
            };
            
            my $enrollment = $db->insert('enrollments', $enrollment_data, { returning => '*' })->hash;
            
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
        
        # Payment successful, move to completion
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
        # Payment failed
        return {
            next_step => $self->id,
            errors => [$result->{error}],
            data => $self->prepare_payment_data($db, $run),
        };
    }
}

method template { 'summer-camp-registration/payment' }

1;