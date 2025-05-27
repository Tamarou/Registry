-- Revert registry:enhanced-pricing-model from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Revert tenant schemas first
DO
$$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants LOOP
        -- Drop index
        EXECUTE format('DROP INDEX IF EXISTS %I.idx_pricing_plans_session_type;', s);
        
        -- Add back old columns
        EXECUTE format('ALTER TABLE %I.pricing_plans ADD COLUMN IF NOT EXISTS early_bird_amount decimal(10,2);', s);
        EXECUTE format('ALTER TABLE %I.pricing_plans ADD COLUMN IF NOT EXISTS early_bird_cutoff_date date;', s);
        EXECUTE format('ALTER TABLE %I.pricing_plans ADD COLUMN IF NOT EXISTS sibling_discount decimal(5,2);', s);
        
        -- Restore data from requirements
        EXECUTE format('UPDATE %I.pricing_plans 
            SET 
                early_bird_cutoff_date = (requirements->>''early_bird_cutoff_date'')::date,
                sibling_discount = (requirements->>''sibling_discount'')::decimal(5,2)
            WHERE requirements IS NOT NULL;', s);
        
        -- Drop new columns
        EXECUTE format('ALTER TABLE %I.pricing_plans DROP CONSTRAINT IF EXISTS check_installment_config;', s);
        EXECUTE format('ALTER TABLE %I.pricing_plans DROP COLUMN IF EXISTS plan_name;', s);
        EXECUTE format('ALTER TABLE %I.pricing_plans DROP COLUMN IF EXISTS plan_type;', s);
        EXECUTE format('ALTER TABLE %I.pricing_plans DROP COLUMN IF EXISTS installments_allowed;', s);
        EXECUTE format('ALTER TABLE %I.pricing_plans DROP COLUMN IF EXISTS installment_count;', s);
        EXECUTE format('ALTER TABLE %I.pricing_plans DROP COLUMN IF EXISTS requirements;', s);
        
        -- Remove duplicate standard entries (keep only early bird)
        EXECUTE format('DELETE FROM %I.pricing_plans WHERE ctid NOT IN (
            SELECT MIN(ctid) FROM %I.pricing_plans GROUP BY session_id
        );', s, s);
        
        -- Restore unique constraint
        EXECUTE format('ALTER TABLE %I.pricing_plans ADD CONSTRAINT pricing_session_id_key UNIQUE (session_id);', s);
        
        -- Rename back to pricing
        EXECUTE format('ALTER TABLE %I.pricing_plans RENAME TO pricing;', s);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Drop index
DROP INDEX IF EXISTS idx_pricing_plans_session_type;

-- Add back old columns
ALTER TABLE pricing_plans ADD COLUMN IF NOT EXISTS early_bird_amount decimal(10,2);
ALTER TABLE pricing_plans ADD COLUMN IF NOT EXISTS early_bird_cutoff_date date;
ALTER TABLE pricing_plans ADD COLUMN IF NOT EXISTS sibling_discount decimal(5,2);

-- Restore data
UPDATE pricing_plans 
SET 
    early_bird_cutoff_date = (requirements->>'early_bird_cutoff_date')::date,
    sibling_discount = (requirements->>'sibling_discount')::decimal(5,2)
WHERE requirements IS NOT NULL;

-- Drop new columns
ALTER TABLE pricing_plans DROP CONSTRAINT IF EXISTS check_installment_config;
ALTER TABLE pricing_plans DROP COLUMN IF EXISTS plan_name;
ALTER TABLE pricing_plans DROP COLUMN IF EXISTS plan_type;
ALTER TABLE pricing_plans DROP COLUMN IF EXISTS installments_allowed;
ALTER TABLE pricing_plans DROP COLUMN IF EXISTS installment_count;
ALTER TABLE pricing_plans DROP COLUMN IF EXISTS requirements;

-- Remove duplicates
DELETE FROM pricing_plans WHERE ctid NOT IN (
    SELECT MIN(ctid) FROM pricing_plans GROUP BY session_id
);

-- Restore unique constraint
ALTER TABLE pricing_plans ADD CONSTRAINT pricing_session_id_key UNIQUE (session_id);

-- Rename back
ALTER TABLE pricing_plans RENAME TO pricing;

COMMIT;