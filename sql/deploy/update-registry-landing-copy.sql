-- Deploy update-registry-landing-copy
-- Re-load the registry landing page template from the filesystem source of truth.

\set template_content `cat templates/registry/tenant-storefront-program-listing.html.ep`

SET search_path TO registry, public;

UPDATE templates
SET content = :'template_content',
    updated_at = now()
WHERE name = 'tenant-storefront/program-listing';
