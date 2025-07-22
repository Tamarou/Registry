---
name: Async Infrastructure Upgrade
about: Track the upgrade of Payment and Database operations to async
title: "Upgrade Payment and Database Operations to Async"
labels: enhancement, performance, async
assignees: ''
---

## Summary

Upgrade Registry's Payment and Database operations to use asynchronous patterns for better performance and scalability. This builds on the new async Stripe service wrapper created in Registry::Service::Stripe.

## Background

Registry currently uses synchronous database and payment operations which can block the event loop and reduce performance under load. With the new async Stripe service wrapper in place, we should extend this pattern to the database layer and payment processing.

## Goals

### Phase 1: Database Layer Async Support
- [ ] Add async methods to Registry::DAO::Object base class
- [ ] Implement async versions of core CRUD operations (create, find, update, delete)
- [ ] Add Mojo::Promise support to database transactions
- [ ] Update connection handling for async operations
- [ ] Add async support to Registry::DAO with proper connection pooling

### Phase 2: Payment Operations Async Upgrade  
- [ ] Migrate Payment workflow steps to use async Stripe operations
- [ ] Update TenantPayment workflow step to use async methods
- [ ] Implement async webhook processing in Registry::Controller::Webhooks
- [ ] Add async payment status polling for long-running operations
- [ ] Update Minion job processing to handle async payment operations

### Phase 3: Controller Integration
- [ ] Update payment-related controllers to use async operations
- [ ] Implement proper promise handling in Mojolicious controllers
- [ ] Add async error handling and user feedback patterns
- [ ] Update payment workflows to use non-blocking operations

### Phase 4: Testing & Performance
- [ ] Add comprehensive async operation tests
- [ ] Performance benchmarking: sync vs async operations
- [ ] Load testing with concurrent payment processing
- [ ] Memory usage optimization for promise chains
- [ ] Update integration tests for async patterns

## Technical Requirements

### Database Async Methods
```perl
# New async DAO methods
method find_async($filter) { ... }
method create_async($data) { ... }  
method update_async($filter, $data) { ... }
method delete_async($filter) { ... }

# Example usage
$dao->find_async({ id => 123 })
    ->then(sub ($record) { ... })
    ->catch(sub ($error) { ... });
```

### Payment Async Integration
```perl
# Already implemented in Registry::Service::Stripe
$payment->create_payment_intent_async($db, $args)
    ->then(sub ($intent) {
        # Update database asynchronously
        return $payment->save_async($db);
    })
    ->then(sub ($result) { ... });
```

### Controller Promise Handling
```perl
# Proper async controller pattern
method process_payment {
    $self->render_later;
    
    $payment->create_payment_intent_async($db, $args)
        ->then(sub ($intent) {
            $self->render(json => { success => 1, intent => $intent });
        })
        ->catch(sub ($error) {
            $self->render(json => { success => 0, error => $error });
        });
}
```

## Performance Benefits

### Expected Improvements
- **Concurrent Operations**: Multiple payments can be processed simultaneously
- **Non-blocking I/O**: Database and Stripe operations won't block other requests
- **Better Resource Utilization**: More efficient use of connections and memory
- **Improved User Experience**: Faster response times for payment operations
- **Scalability**: Better handling of high-load scenarios

### Metrics to Track
- [ ] Payment processing time (sync vs async)
- [ ] Concurrent request handling capacity
- [ ] Memory usage under load
- [ ] Database connection efficiency
- [ ] Error rates and recovery times

## Breaking Changes & Migration

### Backward Compatibility
- Keep existing synchronous methods for gradual migration
- Add `_async` suffix to new async methods
- Provide migration guide for existing code

### Migration Strategy
1. **Phase 1**: Add async methods alongside existing sync methods
2. **Phase 2**: Migrate high-traffic operations (payments, user creation)
3. **Phase 3**: Update controllers and workflows incrementally  
4. **Phase 4**: Deprecate sync methods in favor of async (future release)

## Dependencies

### Prerequisites
- [x] Registry::Service::Stripe async wrapper (completed)
- [ ] Mojo::Pg async connection pooling configuration
- [ ] Promise-based error handling patterns
- [ ] Async-aware testing framework setup

### Related Issues
- Performance issues under high payment load
- Database connection pool exhaustion during peak usage
- Long-running payment operations blocking other requests

## Testing Strategy

### Test Coverage Required
- [ ] Unit tests for all async DAO methods
- [ ] Integration tests for async payment workflows
- [ ] Load tests with concurrent payment processing
- [ ] Error handling and recovery scenarios
- [ ] Memory leak detection for promise chains
- [ ] Webhook processing under load

### Performance Benchmarks
- [ ] Baseline current sync performance
- [ ] Benchmark async improvements
- [ ] Memory usage comparison
- [ ] Concurrent request handling limits

## Definition of Done

- [ ] All new async methods have comprehensive test coverage
- [ ] Performance benchmarks show measurable improvement
- [ ] No regressions in existing functionality
- [ ] Documentation updated with async patterns
- [ ] Migration guide created for developers
- [ ] Code review completed with focus on promise handling
- [ ] Load testing validates improved concurrent processing

## References

- [Mojolicious Async Guide](https://docs.mojolicious.org/Mojolicious/Guides/Cookbook#Non-blocking)
- [Mojo::Promise Documentation](https://docs.mojolicious.org/Mojo/Promise)
- [Registry::Service::Stripe async implementation](lib/Registry/Service/Stripe.pm)