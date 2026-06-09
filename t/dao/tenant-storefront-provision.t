# ABOUTME: Tests that Tenant->provision does not copy the registry marketing template
# ABOUTME: into the tenant schema, so tenants render the catalog, not the marketing page.
use 5.42.0;
use lib qw(lib t/lib);
use experimental qw(defer keyword_any);
use Test::More import => [qw(done_testing is ok)];
defer { done_testing };

use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::Template;
use Test::Registry::DB;
use Test::Registry::Helpers qw(import_all_workflows);

my $t_db = Test::Registry::DB->new;
my $dao  = $t_db->db;
$ENV{DB_URL} = $t_db->uri;
my $db = $dao->db;

import_all_workflows($dao);

# Simulate the production state: the tenant-storefront/program-listing DB template
# exists in the registry schema (with marketing content) and is linked to the
# program-listing workflow step via template_id.
#
# In production, 'registry template import registry' creates this DB template from
# the disk file and links it to the step via set_template().  The test-schema.sql
# seeds the template row (marketing content) but not the step link, so we create
# both here to reproduce the exact production bug path.
#
# The marketing template content is the REGISTRY landing page
# ("Your art deserves a real business") which has CTAs that start 'tenant-signup',
# NOT 'summer-camp-registration'.  When copy_workflow copies this template into the
# tenant schema, DBTemplates serves it to the tenant instead of the disk catalog.
# (refs #173 #229)

my $marketing_content = q{<h1>Your art deserves a real business.</h1><a href="/callcc/tenant-signup">Start your own art education business</a>};

# Ensure the marketing template exists in the registry schema
my $existing_tpl = $dao->find('Registry::DAO::Template' => { name => 'tenant-storefront/program-listing' });
my $marketing_tpl;
if ($existing_tpl) {
    $marketing_tpl = $existing_tpl;
} else {
    $marketing_tpl = $dao->create('Registry::DAO::Template' => {
        name    => 'tenant-storefront/program-listing',
        slug    => 'tenant-storefront-program-listing',
        content => $marketing_content,
        notes   => 'Registry marketing landing page (platform-level)',
    });
}
ok $marketing_tpl, 'registry schema has tenant-storefront/program-listing template';

# Link the template to the program-listing workflow step (simulating 'template import')
my ($storefront_wf) = $dao->find(Workflow => { slug => 'tenant-storefront' });
ok $storefront_wf, 'tenant-storefront workflow exists';

my ($listing_step) = $dao->find(WorkflowStep => { slug => 'program-listing' });
ok $listing_step, 'program-listing step exists';

# Link the marketing template to the workflow step
$listing_step->set_template($dao->db, $marketing_tpl);

# Reload to confirm the link was created
my ($listing_step_reloaded) = $dao->find(WorkflowStep => { id => $listing_step->id });
is $listing_step_reloaded->template_id, $marketing_tpl->id,
    'program-listing step is now linked to the marketing template (production bug precondition)';

# Now provision a tenant -- this calls copy_workflow which would copy the linked
# marketing template into the tenant schema unless provision explicitly removes it.
my $admin = Registry::DAO::User->create($db, {
    username  => 'storefront_prov_admin',
    user_type => 'admin',
    email     => 'storefront_prov_admin@test.com',
    name      => 'Storefront Prov Admin',
});

my $tenant = Registry::DAO::Tenant->provision($db, {
    name  => 'Storefront Provision Test',
    slug  => 'storefront_prov1',
    users => [ $admin ],
});
ok $tenant, 'provision returned a tenant';

# The registry schema seeds a DB template named tenant-storefront/program-listing
# whose content is the REGISTRY marketing page ("Your art deserves a real business").
# copy_workflow copies that template into the tenant schema, and DBTemplates resolves
# DB templates before the filesystem. If the tenant schema has that DB template, a
# parent visiting the tenant storefront sees the marketing page with a tenant-signup
# CTA instead of the program catalog with summer-camp-registration CTAs (refs #173 #229).
#
# After provision, the tenant schema MUST NOT have that marketing template row.
# DBTemplates will then fall back to the filesystem template, i.e. the catalog.

my $tenant_dao = Registry::DAO->new(url => $ENV{DB_URL}, schema => $tenant->slug);
my $tenant_db  = $tenant_dao->db;

my $tenant_marketing_tpl = $tenant_db->select(
    'templates',
    ['id', 'name'],
    { name => 'tenant-storefront/program-listing' },
)->hash;

ok !$tenant_marketing_tpl,
    'provisioned tenant schema has NO tenant-storefront/program-listing template (catalog uses filesystem fallback)';

# The workflow step itself must still exist (workflow intact, just no overriding DB template)
my ($tenant_storefront_wf) = $tenant_dao->find(Workflow => { slug => 'tenant-storefront' });
ok $tenant_storefront_wf, 'tenant-storefront workflow still exists after provision';

my ($tenant_listing_step) = $tenant_dao->find(WorkflowStep => { slug => 'program-listing' });
ok $tenant_listing_step, 'program-listing workflow step still exists';

# template_id must be NULL after the marketing template was removed; that is correct.
# The step renders by name (tenant-storefront/program-listing) not by template_id.
ok !$tenant_listing_step->template_id,
    'program-listing step has no template_id (renders by name via filesystem fallback)';
