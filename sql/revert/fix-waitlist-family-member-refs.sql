-- Revert registry:fix-waitlist-family-member-refs from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Re-add the foreign key constraint if we need to revert
-- (Note: This would only work if all student_id values reference valid users)
-- ALTER TABLE waitlist ADD CONSTRAINT waitlist_student_id_fkey FOREIGN KEY (student_id) REFERENCES users(id);

-- For now, we'll just acknowledge the revert without re-adding the problematic constraint
-- since the original constraint was incorrect (should reference family_members, not users)

COMMIT;