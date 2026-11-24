# ABOUTME: attendance-check workflow step kept as a no-op: the job now schedules its own next run.
# ABOUTME: Left in place so stored runs that point at it still resolve; removal waits on ruling 01a20490.
use 5.42.0;

use Object::Pad;

class Registry::DAO::WorkflowSteps::AttendanceCheck::ScheduleNext :isa(Registry::DAO::WorkflowStep) {

    # Nothing to do: the attendance_check job queues its own next run
    # (Registry::Job::Recurring). This step once did it from an app object in
    # run data, which a jsonb column cannot hold, so it never scheduled.
    method process($db, $continuation, $run = undef) {
        return;
    }
}
