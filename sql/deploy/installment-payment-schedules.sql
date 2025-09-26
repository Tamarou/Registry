-- Deploy registry:installment-payment-schedules to pg
-- requires: payments

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Payment schedules for installment plans
CREATE TABLE registry.payment_schedules (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    enrollment_id UUID NOT NULL,
    pricing_plan_id UUID NOT NULL,
    stripe_subscription_id VARCHAR(255),
    total_amount DECIMAL(10,2) NOT NULL,
    installment_amount DECIMAL(10,2) NOT NULL,
    installment_count INTEGER NOT NULL,
    first_payment_date DATE NOT NULL,
    frequency VARCHAR(20) DEFAULT 'monthly' CHECK (frequency IN ('monthly', 'weekly', 'bi_weekly')),
    status VARCHAR(20) DEFAULT 'active' CHECK (status IN ('active', 'completed', 'cancelled', 'suspended')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Individual scheduled payments
CREATE TABLE registry.scheduled_payments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    payment_schedule_id UUID NOT NULL REFERENCES registry.payment_schedules(id) ON DELETE CASCADE,
    payment_id UUID REFERENCES registry.payments(id),
    installment_number INTEGER NOT NULL,
    due_date DATE NOT NULL,
    amount DECIMAL(10,2) NOT NULL,
    status VARCHAR(20) DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'completed', 'failed', 'cancelled')),
    attempt_count INTEGER DEFAULT 0,
    last_attempt_at TIMESTAMP WITH TIME ZONE,
    paid_at TIMESTAMP WITH TIME ZONE,
    failed_at TIMESTAMP WITH TIME ZONE,
    failure_reason TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Create indexes for performance
CREATE INDEX idx_payment_schedules_enrollment ON registry.payment_schedules(enrollment_id);
CREATE INDEX idx_payment_schedules_pricing_plan ON registry.payment_schedules(pricing_plan_id);
CREATE INDEX idx_payment_schedules_stripe_subscription ON registry.payment_schedules(stripe_subscription_id);
CREATE INDEX idx_payment_schedules_status ON registry.payment_schedules(status);

CREATE INDEX idx_scheduled_payments_schedule ON registry.scheduled_payments(payment_schedule_id);
CREATE INDEX idx_scheduled_payments_payment ON registry.scheduled_payments(payment_id);
CREATE INDEX idx_scheduled_payments_status ON registry.scheduled_payments(status);
CREATE INDEX idx_scheduled_payments_due_date ON registry.scheduled_payments(due_date);
CREATE INDEX idx_scheduled_payments_processing ON registry.scheduled_payments(status, due_date) WHERE status IN ('pending', 'failed');

-- Add triggers for updated_at
CREATE TRIGGER update_payment_schedules_updated_at
    BEFORE UPDATE ON registry.payment_schedules
    FOR EACH ROW
    EXECUTE FUNCTION registry.update_updated_at_column();

CREATE TRIGGER update_scheduled_payments_updated_at
    BEFORE UPDATE ON registry.scheduled_payments
    FOR EACH ROW
    EXECUTE FUNCTION registry.update_updated_at_column();

-- Add constraints for business rules
ALTER TABLE registry.payment_schedules
    ADD CONSTRAINT check_installment_count
    CHECK (installment_count > 1);

ALTER TABLE registry.payment_schedules
    ADD CONSTRAINT check_installment_amount
    CHECK (installment_amount > 0);

ALTER TABLE registry.payment_schedules
    ADD CONSTRAINT check_total_amount
    CHECK (total_amount > 0);

ALTER TABLE registry.scheduled_payments
    ADD CONSTRAINT check_installment_number
    CHECK (installment_number > 0);

ALTER TABLE registry.scheduled_payments
    ADD CONSTRAINT check_scheduled_amount
    CHECK (amount > 0);

COMMIT;