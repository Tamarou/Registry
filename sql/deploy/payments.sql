-- Deploy registry:payments to pg
-- requires: schema-based-multitennancy

BEGIN;

-- Create payments table in registry schema
CREATE TABLE registry.payments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES registry.users(id),
    amount DECIMAL(10,2) NOT NULL,
    currency VARCHAR(3) DEFAULT 'USD',
    status VARCHAR(50) NOT NULL DEFAULT 'pending',
    stripe_payment_intent_id VARCHAR(255),
    stripe_payment_method_id VARCHAR(255),
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    completed_at TIMESTAMP WITH TIME ZONE,
    error_message TEXT
);

-- Add indexes
CREATE INDEX idx_payments_user_id ON registry.payments(user_id);
CREATE INDEX idx_payments_status ON registry.payments(status);
CREATE INDEX idx_payments_stripe_intent ON registry.payments(stripe_payment_intent_id);

-- Create payment_items table for line items
CREATE TABLE registry.payment_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    payment_id UUID NOT NULL REFERENCES registry.payments(id) ON DELETE CASCADE,
    enrollment_id UUID,
    description TEXT NOT NULL,
    amount DECIMAL(10,2) NOT NULL,
    quantity INTEGER DEFAULT 1,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_payment_items_payment_id ON registry.payment_items(payment_id);

-- Add trigger to update updated_at
CREATE TRIGGER update_payments_updated_at
    BEFORE UPDATE ON registry.payments
    FOR EACH ROW
    EXECUTE FUNCTION registry.update_updated_at_column();

COMMIT;