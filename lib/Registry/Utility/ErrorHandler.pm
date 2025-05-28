use 5.34.0;
use experimental 'signatures';
use Object::Pad;

class Registry::Utility::ErrorHandler {
    use Carp qw(croak);
    use JSON qw(encode_json decode_json);
    use Scalar::Util qw(blessed);

    # Error type constants
    use constant {
        ERROR_PAYMENT_FAILED => 'payment_failed',
        ERROR_VALIDATION => 'validation_error',
        ERROR_CONFLICT => 'data_conflict',
        ERROR_SYSTEM => 'system_error',
        ERROR_NETWORK => 'network_error',
        ERROR_AUTH => 'authentication_error',
        ERROR_TIMEOUT => 'timeout_error',
        ERROR_RATE_LIMIT => 'rate_limit_error'
    };

    # Error handling for payment failures
    method handle_payment_error($error, $context = {}) {
        my $error_data = $self->_extract_stripe_error($error);
        
        my $user_message = $self->_get_payment_user_message($error_data);
        my $should_retry = $self->_payment_is_retryable($error_data);
        my $support_needed = $self->_payment_needs_support($error_data);
        
        return {
            type => ERROR_PAYMENT_FAILED,
            user_message => $user_message,
            technical_message => $error_data->{message} // "$error",
            code => $error_data->{code},
            should_retry => $should_retry,
            support_needed => $support_needed,
            context => $context,
            timestamp => time(),
            retry_delay => $should_retry ? $self->_get_retry_delay($error_data) : 0
        };
    }

    # Error handling for data validation and conflicts
    method handle_validation_error($field, $message, $value = undef) {
        return {
            type => ERROR_VALIDATION,
            field => $field,
            user_message => $message,
            value => $value,
            timestamp => time(),
            should_retry => 1,  # User can fix validation errors
            support_needed => 0
        };
    }

    # Error handling for data conflicts (like duplicate subdomains)
    method handle_conflict_error($resource, $conflict_type, $details = {}) {
        my $user_message = $self->_get_conflict_user_message($resource, $conflict_type, $details);
        
        return {
            type => ERROR_CONFLICT,
            resource => $resource,
            conflict_type => $conflict_type,
            user_message => $user_message,
            details => $details,
            timestamp => time(),
            should_retry => 1,
            support_needed => 0
        };
    }

    # Error handling for system integration failures
    method handle_system_error($service, $error, $context = {}) {
        my $is_temporary = $self->_is_temporary_error($error);
        my $user_message = $is_temporary ? 
            "Temporary service issue. Please try again in a few moments." :
            "System error occurred. Our team has been notified.";
            
        return {
            type => ERROR_SYSTEM,
            service => $service,
            user_message => $user_message,
            technical_message => "$error",
            is_temporary => $is_temporary,
            should_retry => $is_temporary,
            support_needed => !$is_temporary,
            context => $context,
            timestamp => time(),
            retry_delay => $is_temporary ? 30 : 0  # 30 second delay for temporary errors
        };
    }

    # Error handling for workflow interruptions
    method handle_workflow_interruption($workflow_id, $step_id, $reason, $recovery_data = {}) {
        return {
            type => 'workflow_interruption',
            workflow_id => $workflow_id,
            step_id => $step_id,
            reason => $reason,
            recovery_data => $recovery_data,
            user_message => "Your progress has been saved. You can continue where you left off.",
            timestamp => time(),
            can_recover => 1
        };
    }

    # Generate user-friendly error messages for forms
    method format_form_errors($errors) {
        return [] unless $errors && @$errors;
        
        my @formatted = ();
        for my $error (@$errors) {
            if (ref($error) eq 'HASH') {
                push @formatted, {
                    field => $error->{field},
                    message => $error->{user_message} // $error->{message},
                    type => $error->{type} // 'error'
                };
            } else {
                push @formatted, {
                    field => 'general',
                    message => "$error",
                    type => 'error'
                };
            }
        }
        
        return \@formatted;
    }

    # Log errors for monitoring
    method log_error($error_data, $request_context = {}) {
        # In production, this would integrate with logging service
        my $log_entry = {
            timestamp => time(),
            error => $error_data,
            request => $request_context,
            server_id => $ENV{SERVER_ID} // 'unknown',
            version => $ENV{APP_VERSION} // 'dev'
        };
        
        # Log to STDERR for now (in production, use proper logging service)
        warn "Registry Error: " . encode_json($log_entry);
        
        # If this is a critical error, trigger alerts
        if ($error_data->{support_needed} && !$error_data->{is_temporary}) {
            $self->_trigger_support_alert($error_data, $request_context);
        }
    }

    # Private methods for error processing

    method _extract_stripe_error($error) {
        my $error_data = { message => "$error" };
        
        # If it's a hash reference (our mock/test case)
        if (ref($error) eq 'HASH') {
            $error_data = { %$error };
        }
        # If it's a Stripe error object, extract useful information
        elsif (blessed($error) && $error->can('type')) {
            $error_data->{type} = $error->type;
            $error_data->{code} = $error->code;
            $error_data->{message} = $error->message;
            $error_data->{param} = $error->param if $error->can('param');
        }
        
        return $error_data;
    }

    method _get_payment_user_message($error_data) {
        my $code = $error_data->{code} // '';
        
        return {
            'card_declined' => 'Your card was declined. Please try a different payment method.',
            'insufficient_funds' => 'Insufficient funds. Please try a different card or contact your bank.',
            'invalid_cvc' => 'Invalid security code. Please check your card details.',
            'expired_card' => 'Your card has expired. Please use a different payment method.',
            'incorrect_number' => 'Invalid card number. Please check your card details.',
            'processing_error' => 'Payment processing error. Please try again.',
            'rate_limit' => 'Too many payment attempts. Please wait a few minutes before trying again.'
        }->{$code} // 'Payment failed. Please try again or contact support.';
    }

    method _payment_is_retryable($error_data) {
        my $code = $error_data->{code} // '';
        my $retryable_codes = {
            'processing_error' => 1,
            'rate_limit' => 1,
            'card_declined' => 1,  # User can try different card
            'insufficient_funds' => 1,
            'invalid_cvc' => 1,
            'expired_card' => 1,
            'incorrect_number' => 1
        };
        
        return $retryable_codes->{$code} // 1;  # Default to retryable
    }

    method _payment_needs_support($error_data) {
        my $code = $error_data->{code} // '';
        my $support_codes = {
            'processing_error' => 1,
            'api_connection_error' => 1,
            'api_error' => 1
        };
        
        return $support_codes->{$code} // 0;
    }

    method _get_retry_delay($error_data) {
        my $code = $error_data->{code} // '';
        return {
            'rate_limit' => 300,    # 5 minutes
            'processing_error' => 60,  # 1 minute
        }->{$code} // 30;  # Default 30 seconds
    }

    method _get_conflict_user_message($resource, $conflict_type, $details) {
        if ($resource eq 'subdomain' && $conflict_type eq 'already_exists') {
            my $suggested = $details->{suggested_alternatives} // [];
            my $message = "The subdomain '$details->{attempted}' is already taken.";
            if (@$suggested) {
                $message .= " Try: " . join(', ', @$suggested);
            }
            return $message;
        }
        
        if ($resource eq 'email' && $conflict_type eq 'already_exists') {
            return "An account with this email address already exists. Please use a different email or contact support if this is your account.";
        }
        
        return "The $resource you specified conflicts with existing data. Please try a different value.";
    }

    method _is_temporary_error($error) {
        my $error_string = "$error";
        
        # Check for common temporary error patterns
        return 1 if $error_string =~ /timeout|connection|network|temporary|503|502|500/i;
        return 1 if $error_string =~ /database.*connection|deadlock|lock.*timeout/i;
        return 1 if $error_string =~ /stripe.*connection|api.*rate.*limit/i;
        
        return 0;
    }

    method _trigger_support_alert($error_data, $context) {
        # In production, this would integrate with alerting system (PagerDuty, Slack, etc.)
        warn "CRITICAL ERROR ALERT: " . encode_json({
            type => 'critical_error',
            error => $error_data,
            context => $context,
            timestamp => time()
        });
    }
}