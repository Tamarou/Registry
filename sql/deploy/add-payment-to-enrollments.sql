-- Deploy registry:add-payment-to-enrollments to pg
-- requires: payments
-- requires: summer-camp-module

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Add payment_id to enrollments table
ALTER TABLE enrollments 
ADD COLUMN IF NOT EXISTS payment_id UUID REFERENCES registry.payments(id);

-- Add index for payment lookups
CREATE INDEX IF NOT EXISTS idx_enrollments_payment_id ON enrollments(payment_id);

-- Update existing enrollment records if needed (they will have NULL payment_id)
COMMENT ON COLUMN enrollments.payment_id IS 'Reference to payment record for this enrollment';

COMMIT;