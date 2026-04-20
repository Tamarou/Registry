-- ABOUTME: Seed data for Super Awesome Cool Pottery's registry tenant.
-- ABOUTME: Creates the tenant (if missing) and populates real-world program data.
--
-- Usage:
--     psql 'postgres://...' -v tenant_slug=sacp -f sql/seed/sacp-tenant.sql
--
-- Source: https://superawesomecool.com (studio address, programs offered)
-- Target: populate a single tenant with Super Awesome Cool Pottery's
-- real locations and program types so Victoria can start testing
-- with representative data instead of a blank slate.
--
-- Safe to re-run: every INSERT uses ON CONFLICT DO NOTHING or UPDATE.

\set ON_ERROR_STOP on

BEGIN;

SET client_min_messages = 'warning';

-- -------------------------------------------------------------------------
-- Create the SACP tenant and its schema if neither exists yet.
-- -------------------------------------------------------------------------

DO
$$
DECLARE
    target_slug text := 'sacp';
    target_name text := 'Super Awesome Cool Pottery';
BEGIN
    IF NOT EXISTS (SELECT 1 FROM registry.tenants WHERE slug = target_slug) THEN
        INSERT INTO registry.tenants (slug, name) VALUES (target_slug, target_name);
    END IF;

    IF to_regnamespace(quote_ident(target_slug)) IS NULL THEN
        PERFORM registry.clone_schema(target_slug);
    END IF;
END;
$$ LANGUAGE plpgsql;

SET search_path TO sacp, public;

-- -------------------------------------------------------------------------
-- Program types. clone_schema copies structure only, so seed every type
-- SACP needs directly into the tenant schema.
-- -------------------------------------------------------------------------

INSERT INTO program_types (slug, name, config) VALUES
    ('afterschool',  'After School Program',
        '{"session_pattern": "weekly_for_x_weeks",
          "enrollment_rules": {"same_session_for_siblings": true},
          "standard_times": {
            "monday":    "15:00",
            "tuesday":   "15:00",
            "wednesday": "14:00",
            "thursday":  "15:00",
            "friday":    "15:00"
          }}'::jsonb),
    ('summer-camp',  'Summer Camp',
        '{"session_pattern": "daily_for_x_days",
          "enrollment_rules": {"same_session_for_siblings": false},
          "standard_times": {"start": "09:00", "end": "16:00"}}'::jsonb),
    ('workshop',     'Workshop',
        '{"session_pattern": "one_time", "default_capacity": 12}'::jsonb),
    ('wheel-class',  'Wheel Class',
        '{"session_pattern": "weekly", "default_capacity": 8}'::jsonb),
    ('pyop',         'Paint Your Own Pottery',
        '{"session_pattern": "walk_in"}'::jsonb),
    ('field-trip',   'Field Trip',
        '{"session_pattern": "one_time"}'::jsonb),
    ('birthday-party','Birthday Party',
        '{"session_pattern": "one_time", "default_capacity": 15}'::jsonb)
ON CONFLICT (slug) DO NOTHING;

-- -------------------------------------------------------------------------
-- Locations.
-- -------------------------------------------------------------------------

INSERT INTO locations (slug, name, address_info, capacity)
VALUES (
    'sacp_studio',
    'Super Awesome Cool Pottery Studio',
    '{"street_address": "930 Hoffner Ave",
      "city": "Orlando",
      "state": "FL",
      "postal_code": "32809",
      "phone": "(407) 720-3699",
      "email": "studio@superawesomecool.com"}'::jsonb,
    24  -- studio camp capacity
)
ON CONFLICT (slug) DO UPDATE
SET name         = EXCLUDED.name,
    address_info = EXCLUDED.address_info,
    capacity     = EXCLUDED.capacity,
    updated_at   = now();

INSERT INTO locations (slug, name, address_info, capacity)
VALUES (
    'dr_phillips_elementary',
    'Dr Phillips Elementary',
    '{"street_address": "6909 Dr Phillips Blvd",
      "city": "Orlando",
      "state": "FL",
      "postal_code": "32819",
      "district": "Orange County Public Schools"}'::jsonb,
    20  -- typical afterschool class size
)
ON CONFLICT (slug) DO UPDATE
SET name         = EXCLUDED.name,
    address_info = EXCLUDED.address_info,
    capacity     = EXCLUDED.capacity,
    updated_at   = now();

-- -------------------------------------------------------------------------
-- Sample program templates so Victoria has something to publish against.
-- Programs start as 'draft' so nothing goes live until she explicitly
-- publishes from the admin dashboard.
-- -------------------------------------------------------------------------

INSERT INTO projects (slug, name, program_type_slug, notes, status, metadata)
VALUES (
    'summer_camp_2026',
    'Summer Camp 2026',
    'summer-camp',
    'Full-day summer camp at the studio, grades K-5, Mon-Fri 9am-4pm ' ||
    '(free extended care 8am-6pm). Weekly themes run June 1 through August 10. ' ||
    '$300 per student per week including before/after care.',
    'draft',
    '{"grades": "K-5",
      "daily_start": "09:00",
      "daily_end":   "16:00",
      "extended_care_start": "08:00",
      "extended_care_end":   "18:00",
      "default_price": 300,
      "themes_2026": [
        "Rodeo", "Hollywood Movies", "Outdoor Adventure", "Oceans",
        "Safari", "Hawaiian Sun", "Gardening", "Prehistoric Past",
        "Lil'' Gems in Nature", "Rainforest", "Architecture"]}'::jsonb
)
ON CONFLICT (slug) DO NOTHING;

INSERT INTO projects (slug, name, program_type_slug, notes, status, metadata)
VALUES (
    'after_school_dr_phillips_fall_2026',
    'After-School at Dr Phillips, Fall 2026',
    'afterschool',
    'Weekly after-school pottery program at Dr Phillips Elementary. ' ||
    'Grades K-5, meets 3:00-4:15 PM. Returns August 2026 for the 2026-2027 school year.',
    'draft',
    '{"grades": "K-5",
      "daily_start": "15:00",
      "daily_end":   "16:15",
      "sessions_per_year": 6}'::jsonb
)
ON CONFLICT (slug) DO NOTHING;

COMMIT;

-- -------------------------------------------------------------------------
-- Summary (printed outside the transaction).
-- -------------------------------------------------------------------------

\echo
\echo 'SACP seed complete. Summary:'
SELECT 'program_types' AS table_name, COUNT(*) FROM sacp.program_types
UNION ALL
SELECT 'locations',     COUNT(*) FROM sacp.locations
UNION ALL
SELECT 'projects',      COUNT(*) FROM sacp.projects
ORDER BY table_name;
