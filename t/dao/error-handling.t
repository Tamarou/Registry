#!/usr/bin/env perl
use 5.34.0;
use Test::More;
use Test::Exception;
use Test::Deep;

use lib 't/lib';
use Test::Registry::DB;
use Test::Registry::Fixtures;

use Registry::Utility::ErrorHandler;
use Registry::DAO::WorkflowSteps::TenantPayment;
use Registry::DAO::WorkflowSteps::RegisterTenant;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowRun;

subtest 'ErrorHandler utility class' => sub {
    my $error_handler = Registry::Utility::ErrorHandler->new();
    isa_ok $error_handler, 'Registry::Utility::ErrorHandler';

    subtest 'Payment error handling' => sub {
        # Create a mock error object with a code
        my $mock_error = { code => 'card_declined', message => 'Your card was declined' };
        my $error = $error_handler->handle_payment_error($mock_error);
        
        is $error->{type}, 'payment_failed', 'Correct error type';
        like $error->{user_message}, qr/declined/, 'User-friendly message';
        ok $error->{should_retry}, 'Card declined is retryable';
        is $error->{support_needed}, 0, 'No support needed for declined card';
    };

    subtest 'Validation error handling' => sub {
        my $error = $error_handler->handle_validation_error(
            'email', 
            'Invalid email format', 
            'not-an-email'
        );
        
        is $error->{type}, 'validation_error', 'Correct error type';
        is $error->{field}, 'email', 'Correct field';
        is $error->{user_message}, 'Invalid email format', 'Correct message';
        is $error->{value}, 'not-an-email', 'Stores invalid value';
        ok $error->{should_retry}, 'Validation errors are retryable';
    };

    subtest 'Conflict error handling' => sub {
        my $error = $error_handler->handle_conflict_error(
            'subdomain', 
            'already_exists',
            { attempted => 'test', suggested_alternatives => ['test-1', 'test-2'] }
        );
        
        is $error->{type}, 'data_conflict', 'Correct error type';
        is $error->{resource}, 'subdomain', 'Correct resource';
        is $error->{conflict_type}, 'already_exists', 'Correct conflict type';
        like $error->{user_message}, qr/already taken/, 'Helpful user message';
        like $error->{user_message}, qr/test-1/, 'Includes suggestions';
    };

    subtest 'System error handling' => sub {
        my $error = $error_handler->handle_system_error(
            'database', 
            'Connection timeout'
        );
        
        is $error->{type}, 'system_error', 'Correct error type';
        is $error->{service}, 'database', 'Correct service';
        ok $error->{is_temporary}, 'Timeout is temporary';
        ok $error->{should_retry}, 'Temporary errors are retryable';
        ok $error->{retry_delay} > 0, 'Has retry delay';
    };

    subtest 'Form error formatting' => sub {
        my $errors = [
            { field => 'email', user_message => 'Invalid email' },
            'General error message'
        ];
        
        my $formatted = $error_handler->format_form_errors($errors);
        
        is scalar(@$formatted), 2, 'Correct number of errors';
        is $formatted->[0]{field}, 'email', 'First error field';
        is $formatted->[0]{message}, 'Invalid email', 'First error message';
        is $formatted->[1]{field}, 'general', 'Second error field';
        is $formatted->[1]{message}, 'General error message', 'Second error message';
    };
};

subtest 'Error handling utility methods' => sub {
    my $error_handler = Registry::Utility::ErrorHandler->new();
    
    subtest 'Error type constants' => sub {
        is Registry::Utility::ErrorHandler::ERROR_PAYMENT_FAILED, 'payment_failed', 'Payment failed constant';
        is Registry::Utility::ErrorHandler::ERROR_VALIDATION, 'validation_error', 'Validation error constant';
        is Registry::Utility::ErrorHandler::ERROR_CONFLICT, 'data_conflict', 'Conflict error constant';
    };
    
    subtest 'User message generation for payments' => sub {
        my $payment_error = $error_handler->handle_payment_error({
            code => 'insufficient_funds',
            message => 'Insufficient funds'
        });
        
        like $payment_error->{user_message}, qr/insufficient funds/i, 'Insufficient funds message';
        ok $payment_error->{should_retry}, 'Insufficient funds is retryable';
    };
};

subtest 'Workflow interruption and recovery' => sub {
    my $error_handler = Registry::Utility::ErrorHandler->new();
    
    my $interruption = $error_handler->handle_workflow_interruption(
        'wf_123', 
        'step_payment', 
        'browser_refresh',
        { last_completed_step => 'profile', can_resume => 1 }
    );
    
    is $interruption->{type}, 'workflow_interruption', 'Correct error type';
    is $interruption->{workflow_id}, 'wf_123', 'Workflow ID preserved';
    is $interruption->{reason}, 'browser_refresh', 'Interruption reason recorded';
    ok $interruption->{can_recover}, 'Recovery is possible';
    like $interruption->{user_message}, qr/progress.*saved/i, 'Reassuring message';
};

done_testing;