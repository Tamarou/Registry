-- Verify registry:magic-link-expiry-one-hour

SET search_path TO registry, public;

-- The default itself, by value rather than by text match on the expression.
DO $$
DECLARE
    d text;
BEGIN
    SELECT column_default INTO d
      FROM information_schema.columns
     WHERE table_schema = 'registry'
       AND table_name   = 'tenants'
       AND column_name  = 'magic_link_expiry_hours';

    IF d IS NULL OR d !~ '\m1\M' THEN
        RAISE EXCEPTION
          'tenants.magic_link_expiry_hours default is %, expected 1', d;
    END IF;
END
$$;

-- And that nothing is left on the window this change replaced. Asserted as an
-- invariant rather than a count: a tenant may legitimately choose any other
-- value, but none should still be sitting on the old default.
DO $$
DECLARE
    stragglers integer;
BEGIN
    SELECT COUNT(*) INTO stragglers
      FROM tenants WHERE magic_link_expiry_hours = 24;

    IF stragglers > 0 THEN
        RAISE EXCEPTION
          '% tenant(s) still on the 24-hour magic-link default', stragglers;
    END IF;
END
$$;
