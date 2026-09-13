-- ABOUTME: No-op revert: the cleared stamps were wrong and cannot be restored.
-- ABOUTME: An unstamped row is the safe state -- import reconciles it from the file.

-- Revert registry:clear-template-import-stamps from pg

BEGIN;

-- Deliberately does nothing. The values this change removed were hashes of a
-- form that is no longer compared against, so restoring them would reinstate
-- the defect rather than the data. An unstamped row is the state import treats
-- as reconcilable, which is where a revert wants to leave things anyway.

COMMIT;
