-- ABOUTME: Verify no stored workflow, in registry or any tenant schema, still has the schedule-next step.
-- ABOUTME: Its class is deleted, so a step row naming it could not be run.

-- Verify registry:attendance-check-drops-schedule-next on pg

BEGIN;

DO $$
DECLARE
    s name;
    found boolean;
BEGIN
    FOR s IN
        SELECT 'registry'::name
        UNION ALL
        SELECT slug::name FROM registry.tenants WHERE slug != 'registry'
    LOOP
        CONTINUE WHEN to_regclass(format('%I.workflow_steps', s)) IS NULL;
        EXECUTE format($sql$
            SELECT EXISTS (SELECT 1 FROM %I.workflow_steps
                            WHERE class = 'Registry::DAO::WorkflowSteps::AttendanceCheck::ScheduleNext')
        $sql$, s) INTO found;
        IF found THEN
            RAISE EXCEPTION 'schema % still stores the schedule-next step', s;
        END IF;
    END LOOP;
END $$;

ROLLBACK;
