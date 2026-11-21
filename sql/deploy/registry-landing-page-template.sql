-- Deploy registry-landing-page-template
-- Customize the registry tenant's storefront template for Jordan's user journey.
-- Source of truth for template content: templates/registry/tenant-storefront-program-listing.html.ep

\set template_content `cat templates/registry/tenant-storefront-program-listing.html.ep`

SET search_path TO registry, public;

INSERT INTO templates (name, slug, content, metadata, notes)
VALUES (
    'tenant-storefront/program-listing',
    'tenant-storefront-program-listing',
    :'template_content',
    '{}'::jsonb,
    'Registry tenant landing page for Jordan (art teacher) user journey'
)
ON CONFLICT (name) DO UPDATE SET
    content = EXCLUDED.content,
    notes = EXCLUDED.notes,
    updated_at = now();
