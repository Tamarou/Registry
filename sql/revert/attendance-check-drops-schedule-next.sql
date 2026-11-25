-- ABOUTME: Puts the schedule-next step back as the last step of every stored attendance-check workflow.
-- ABOUTME: Runs that ended on the step before it move forward onto it, so they still read as completed.

-- Revert registry:attendance-check-drops-schedule-next from pg

BEGIN;

SET client_min_messages = 'warning';

DO $$
DECLARE
    s name;
BEGIN
    FOR s IN
        SELECT 'registry'::name
        UNION ALL
        SELECT slug::name FROM registry.tenants WHERE slug != 'registry'
    LOOP
        CONTINUE WHEN to_regclass(format('%I.workflow_steps', s)) IS NULL;
        EXECUTE format($sql$
            INSERT INTO %1$I.workflow_steps (slug, description, workflow_id, depends_on, class)
            SELECT 'schedule-next', 'Schedule the next attendance check job', w.id, u.id,
                   'Registry::DAO::WorkflowSteps::AttendanceCheck::ScheduleNext'
              FROM %1$I.workflows w
              JOIN %1$I.workflow_steps u ON u.workflow_id = w.id AND u.slug = 'check-upcoming-events'
             WHERE w.slug = 'attendance-check'
               AND NOT EXISTS (SELECT 1 FROM %1$I.workflow_steps x
                                WHERE x.workflow_id = w.id AND x.slug = 'schedule-next')
        $sql$, s);
        -- completed() compares a run's latest step with the workflow's last,
        -- which schedule-next is again.
        EXECUTE format($sql$
            UPDATE %1$I.workflow_runs r
               SET latest_step_id = sn.id
              FROM %1$I.workflow_steps sn
             WHERE sn.class = 'Registry::DAO::WorkflowSteps::AttendanceCheck::ScheduleNext'
               AND r.latest_step_id = sn.depends_on
        $sql$, s);
    END LOOP;
END $$;

COMMIT;
