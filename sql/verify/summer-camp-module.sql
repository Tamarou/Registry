-- Verify registry:summer-camp-module on pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Verify location table columns
SELECT
    address_street,
    address_city,
    address_state,
    address_zip,
    capacity,
    contact_info,
    facilities,
    latitude,
    longitude
FROM locations
WHERE false;

-- Verify event table columns
SELECT
    event_type,
    status
FROM events
WHERE false;

-- Verify session table columns
SELECT
    session_type,
    capacity
FROM sessions
WHERE false;

-- Verify session_teachers table
SELECT
    id,
    session_id,
    teacher_id
FROM session_teachers
WHERE false;

-- Verify pricing table (will be renamed to pricing_plans in enhanced-pricing-model)
-- Check for both names since verification runs after all deployments
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'registry' AND table_name = 'pricing') THEN
        -- Table is still called pricing
        PERFORM id, session_id, amount, currency, early_bird_amount, early_bird_cutoff_date, sibling_discount
        FROM pricing
        WHERE false;
    ELSIF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'registry' AND table_name = 'pricing_plans') THEN
        -- Table has been renamed to pricing_plans
        PERFORM id, session_id, amount, currency
        FROM pricing_plans
        WHERE false;
    ELSE
        RAISE EXCEPTION 'Neither pricing nor pricing_plans table exists';
    END IF;
END $$;

-- Verify enrollments table
SELECT
    id,
    session_id,
    student_id,
    status
FROM enrollments
WHERE false;

ROLLBACK;
