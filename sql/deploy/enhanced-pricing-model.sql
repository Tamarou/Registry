-- Deploy registry:enhanced-pricing-model to pg
-- requires: summer-camp-module

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- First, rename the existing pricing table to pricing_plans
ALTER TABLE pricing RENAME TO pricing_plans;

-- Drop the unique constraint on session_id since we'll allow multiple plans per session
ALTER TABLE pricing_plans DROP CONSTRAINT IF EXISTS pricing_session_id_key;

-- Add new columns for enhanced pricing model
ALTER TABLE pricing_plans ADD COLUMN IF NOT EXISTS plan_name text NOT NULL DEFAULT 'Standard';
ALTER TABLE pricing_plans ADD COLUMN IF NOT EXISTS plan_type text NOT NULL DEFAULT 'standard' 
    CHECK (plan_type IN ('standard', 'early_bird', 'family'));
ALTER TABLE pricing_plans ADD COLUMN IF NOT EXISTS installments_allowed boolean DEFAULT false;
ALTER TABLE pricing_plans ADD COLUMN IF NOT EXISTS installment_count integer;
ALTER TABLE pricing_plans ADD COLUMN IF NOT EXISTS requirements jsonb NOT NULL DEFAULT '{}';

-- Migrate existing early bird data to requirements
UPDATE pricing_plans 
SET 
    requirements = jsonb_build_object(
        'early_bird_cutoff_date', early_bird_cutoff_date,
        'sibling_discount', sibling_discount
    ),
    plan_type = CASE 
        WHEN early_bird_amount IS NOT NULL THEN 'early_bird'
        WHEN sibling_discount IS NOT NULL THEN 'family'
        ELSE 'standard'
    END,
    plan_name = CASE
        WHEN early_bird_amount IS NOT NULL THEN 'Early Bird Special'
        WHEN sibling_discount IS NOT NULL THEN 'Family Plan'
        ELSE 'Standard'
    END
WHERE early_bird_amount IS NOT NULL OR sibling_discount IS NOT NULL;

-- Create a standard pricing plan for sessions that had early bird pricing
INSERT INTO pricing_plans (session_id, plan_name, plan_type, amount, currency, requirements, metadata)
SELECT 
    session_id,
    'Standard',
    'standard',
    amount,
    currency,
    '{}',
    metadata
FROM pricing_plans
WHERE plan_type = 'early_bird';

-- Update early bird plans to use early_bird_amount as the amount
UPDATE pricing_plans
SET amount = early_bird_amount
WHERE plan_type = 'early_bird' AND early_bird_amount IS NOT NULL;

-- Drop old columns
ALTER TABLE pricing_plans DROP COLUMN IF EXISTS early_bird_amount;
ALTER TABLE pricing_plans DROP COLUMN IF EXISTS early_bird_cutoff_date;
ALTER TABLE pricing_plans DROP COLUMN IF EXISTS sibling_discount;

-- Add constraint for installment configuration
ALTER TABLE pricing_plans ADD CONSTRAINT check_installment_config 
    CHECK ((installments_allowed = false AND installment_count IS NULL) OR 
           (installments_allowed = true AND installment_count > 1));

-- Create index for better query performance
CREATE INDEX idx_pricing_plans_session_type ON pricing_plans(session_id, plan_type);

-- Propagate changes to tenant schemas
DO
$$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants LOOP
        -- Rename table
        EXECUTE format('ALTER TABLE IF EXISTS %I.pricing RENAME TO pricing_plans;', s);
        
        -- Drop unique constraint
        EXECUTE format('ALTER TABLE %I.pricing_plans DROP CONSTRAINT IF EXISTS pricing_session_id_key;', s);
        
        -- Add new columns
        EXECUTE format('ALTER TABLE %I.pricing_plans ADD COLUMN IF NOT EXISTS plan_name text NOT NULL DEFAULT ''Standard'';', s);
        EXECUTE format('ALTER TABLE %I.pricing_plans ADD COLUMN IF NOT EXISTS plan_type text NOT NULL DEFAULT ''standard'' 
            CHECK (plan_type IN (''standard'', ''early_bird'', ''family''));', s);
        EXECUTE format('ALTER TABLE %I.pricing_plans ADD COLUMN IF NOT EXISTS installments_allowed boolean DEFAULT false;', s);
        EXECUTE format('ALTER TABLE %I.pricing_plans ADD COLUMN IF NOT EXISTS installment_count integer;', s);
        EXECUTE format('ALTER TABLE %I.pricing_plans ADD COLUMN IF NOT EXISTS requirements jsonb NOT NULL DEFAULT ''{}'';', s);
        
        -- Migrate existing data
        EXECUTE format('UPDATE %I.pricing_plans 
            SET 
                requirements = jsonb_build_object(
                    ''early_bird_cutoff_date'', early_bird_cutoff_date,
                    ''sibling_discount'', sibling_discount
                ),
                plan_type = CASE 
                    WHEN early_bird_amount IS NOT NULL THEN ''early_bird''
                    WHEN sibling_discount IS NOT NULL THEN ''family''
                    ELSE ''standard''
                END,
                plan_name = CASE
                    WHEN early_bird_amount IS NOT NULL THEN ''Early Bird Special''
                    WHEN sibling_discount IS NOT NULL THEN ''Family Plan''
                    ELSE ''Standard''
                END
            WHERE early_bird_amount IS NOT NULL OR sibling_discount IS NOT NULL;', s);
        
        -- Create standard plans for early bird sessions
        EXECUTE format('INSERT INTO %I.pricing_plans (session_id, plan_name, plan_type, amount, currency, requirements, metadata)
            SELECT 
                session_id,
                ''Standard'',
                ''standard'',
                amount,
                currency,
                ''{}'',
                metadata
            FROM %I.pricing_plans
            WHERE plan_type = ''early_bird'';', s, s);
        
        -- Update early bird amounts
        EXECUTE format('UPDATE %I.pricing_plans
            SET amount = early_bird_amount
            WHERE plan_type = ''early_bird'' AND early_bird_amount IS NOT NULL;', s);
        
        -- Drop old columns
        EXECUTE format('ALTER TABLE %I.pricing_plans DROP COLUMN IF EXISTS early_bird_amount;', s);
        EXECUTE format('ALTER TABLE %I.pricing_plans DROP COLUMN IF EXISTS early_bird_cutoff_date;', s);
        EXECUTE format('ALTER TABLE %I.pricing_plans DROP COLUMN IF EXISTS sibling_discount;', s);
        
        -- Add constraints
        EXECUTE format('ALTER TABLE %I.pricing_plans ADD CONSTRAINT check_installment_config 
            CHECK ((installments_allowed = false AND installment_count IS NULL) OR 
                   (installments_allowed = true AND installment_count > 1));', s);
        
        -- Create index
        EXECUTE format('CREATE INDEX idx_pricing_plans_session_type ON %I.pricing_plans(session_id, plan_type);', s);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMIT;