# Plan Review Findings: Stripe Connect Integration

These corrections MUST be applied during execution of the plan at
`docs/superpowers/plans/2026-03-24-stripe-connect-integration.md`.

## Blockers (fix before or during execution)

### 1. Service::Stripe `_request` method does not exist

The plan's new Connect methods call `$self->_request(...)` which doesn't exist.

**Fix:** Use `$self->_request_async('POST', 'accounts', $args)->wait` pattern (matching
existing sync wrappers at line 233+). Also strip `/v1/` prefix from endpoints -- the
`_request_async` method already prepends `https://api.stripe.com/v1/`.

Correct pattern:
```perl
method create_account_async ($args) {
    return $self->_request_async('POST', 'accounts', $args);
}
method create_account ($args) {
    return $self->create_account_async($args)->wait;
}
```

### 2. `Subscription.pm` writes to dropped columns

`lib/Registry/DAO/Subscription.pm` line 138 writes `stripe_subscription_id`, `billing_status`,
`trial_ends_at`, `subscription_started_at` to the tenants table. The migration drops these columns.
The webhook controller dispatches non-Connect events to `Subscription->process_webhook_event`
which will crash.

**Fix:** Add a task between Task 1 (migration) and Task 4 (webhook) to:
- Remove tenant column writes from `Subscription.pm` or guard them
- Update the webhook controller's dispatch to not route `account.updated` through Subscription
- At minimum, make the Subscription webhook path a no-op for tenant billing events

### 3. `table` method needs `registry.` schema prefix

**Fix:** Change `sub table { 'tenant_stripe_accounts' }` to
`sub table { 'registry.tenant_stripe_accounts' }` in TenantStripeAccount.pm.

### 4. `Client::Stripe->new()` dies before guard in RegisterTenant

`Registry::Client::Stripe->new()` calls `die "STRIPE_SECRET_KEY not set"` in its ADJUST block.
The plan's `unless ($ENV{STRIPE_SECRET_KEY})` guard comes after `new()`.

**Fix:** Restructure to check the env var BEFORE instantiation:
```perl
my $stripe_account_id;
if ($ENV{STRIPE_SECRET_KEY}) {
    my $client = Registry::Client::Stripe->new();
    # ... create account ...
} else {
    $stripe_account_id = 'acct_test_' . substr($tenant->id, 0, 8);
}
```

### 5. `PricingRelationship.consumer_id` is a USER ID, not tenant ID

`consumer_id` throughout the codebase is a user ID (see `get_consumer_user` method).
The plan's `calculate_application_fee` searches with `consumer_id => $tenant_id` which will
never match.

**Fix:** Look up the tenant's primary user first, then find their pricing relationship:
```perl
sub calculate_application_fee ($class, $db, $tenant_id, $amount_cents) {
    my $platform_uuid = '00000000-0000-0000-0000-000000000000';

    # Find tenant's primary user for the pricing relationship lookup
    my $tenant = Registry::DAO::Tenant->find($db, { id => $tenant_id });
    my $primary_user = $tenant ? $tenant->primary_user($db) : undef;

    my $revenue_share_percent = 2.5;  # fallback default

    if ($primary_user) {
        my @relationships = Registry::DAO::PricingRelationship->find($db, {
            provider_id => $platform_uuid,
            consumer_id => $primary_user->id,
            status => 'active',
        });
        if (@relationships) {
            my $plan = $relationships[0]->get_pricing_plan($db);
            if ($plan && $plan->pricing_configuration->{revenue_share_percent}) {
                $revenue_share_percent = $plan->pricing_configuration->{revenue_share_percent};
            }
        }
    }

    return int($amount_cents * $revenue_share_percent / 100);
}
```

Test fixtures must also create the PricingRelationship with `consumer_id` as the tenant's
primary user ID, not the tenant ID.

### 6. `find_by_tenant` must be `sub`, not `method`

The plan shows `method find_by_tenant` then a note saying to use `sub`. Only the `sub`
version is correct:
```perl
sub find_by_tenant ($class, $db, $tenant_id) {
    $class->find($db, { tenant_id => $tenant_id });
}
```

## High Priority

### 7. Move Task 8 (Stripe-Account header) to immediately after Task 3

Connect methods aren't usable for direct charges until `_request_async` supports
the `Stripe-Account` header. Merge Task 8 into Task 3 or move it to Task 3b.

### 8. `_handle_account_updated` should not call `$self->render`

The existing webhook pattern (e.g., `_process_installment_payment_event`) returns without
rendering. The outer `stripe` method renders the final response. If `_handle_account_updated`
also renders, Mojolicious will double-render.

**Fix:** Return without rendering. Let the outer method handle it:
```perl
method _handle_account_updated ($event_data) {
    # ... update logic ...
    return 1;  # outer method handles the render
}
```

## Medium Priority

### 9. Add fallback test with warning for missing PricingRelationship

Add a subtest to `payment-connect-charges.t` for a tenant with no pricing relationship.
Verify it falls back to 2.5% and emits a warning.

### 10. Enumerate specific test files to update in Task 10

Known files that reference dropped columns or old payment step:
- `t/dao/tenant-payment-workflow.t` -- tests TenantPayment directly (keep, class still exists)
- `t/controller/tenant-signup-data-flow.t` -- walks signup flow, may hit removed payment step
- `t/controller/tenant-pricing-display.t` -- walks signup flow through review
- `t/integration/stripe-connect-signup.t` -- new test, should be correct
- `t/dao/stripe-subscription.t` -- if exists, tests old subscription model
- Any test referencing `billing_status`, `trial_ends_at`, `stripe_subscription_id`
