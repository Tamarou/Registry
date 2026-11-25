-- ABOUTME: Removes the no-op schedule-next step from every stored attendance-check workflow, in registry and each tenant.
-- ABOUTME: The attendance_check job queues its own next run; runs that ended on the step now end on the step before it.

-- Deploy registry:attendance-check-drops-schedule-next to pg
-- requires: workflow-roles-data

BEGIN;

SET client_min_messages = 'warning';

-- from_yaml short-circuits on an existing slug, so the YAML alone changes no
-- stored copy. The step was last, so dropping its row leaves the workflow the
-- shape the YAML now ships; the runs that ended on it keep their history.
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
            UPDATE %1$I.workflow_runs r
               SET latest_step_id = st.depends_on
              FROM %1$I.workflow_steps st
             WHERE r.latest_step_id = st.id
               AND st.class = 'Registry::DAO::WorkflowSteps::AttendanceCheck::ScheduleNext'
        $sql$, s);
        EXECUTE format($sql$
            DELETE FROM %I.workflow_steps
             WHERE class = 'Registry::DAO::WorkflowSteps::AttendanceCheck::ScheduleNext'
        $sql$, s);
    END LOOP;
END $$;

COMMIT;
