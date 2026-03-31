-- Verify registry:magic-link-verification on pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

SELECT verified_at
  FROM magic_link_tokens
 WHERE false;

ROLLBACK;
