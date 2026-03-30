-- Revert registry:auth-notification-types from pg
--
-- PostgreSQL does not support ALTER TYPE ... DROP VALUE for enums.
-- The added values are harmless if unused, so the revert is a no-op.
-- A full revert would require recreating the type, which is destructive.

-- No-op: enum values cannot be removed without recreating the type.
