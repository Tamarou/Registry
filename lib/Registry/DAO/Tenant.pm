# ABOUTME: DAO for tenant organizations. Manages tenant creation, schema
# ABOUTME: isolation, user association, and domain configuration.
use 5.42.0;
use Object::Pad;

class Registry::DAO::Tenant :isa(Registry::DAO::Object) {
    use Registry::DAO::Workflow;
    use Registry::DAO::OutcomeDefinition;
    use Registry::DAO;
    field $id :param :reader = undef;
    field $name :param :reader;
    field $slug :param :reader //= lc( $name =~ s/\s+/_/gr );
    field $created_at :param :reader;
    field $canonical_domain :param :reader = undef;
    field $magic_link_expiry_hours :param :reader = 24;
    field $stripe_connect_account_id :param :reader = undef;
    field $stripe_charges_enabled    :param :reader = 0;
    field $stripe_details_submitted  :param :reader = 0;

    sub table { 'tenants' }

    sub create ( $class, $db, $data ) {
        $data->{slug} //= lc( $data->{name} =~ s/\s+/_/gr );
        $class->SUPER::create( $db, $data );
    }

    method dao($db = undef) { 
        # If we have a db handle that's part of a Registry::DAO object, get the URL from there
        if ($db && $db isa Registry::DAO) {
            return Registry::DAO->new( url => $db->url, schema => $slug );
        } 
        # If we have a raw database handle, connect using ENV{DB_URL}
        elsif ($db) {
            return Registry::DAO->new( schema => $slug );
        } 
        # No db handle, just use the default URL
        else {
            return Registry::DAO->new( schema => $slug );
        }
    }

    method primary_user ($db) {
        my $sql = <<~'SQL';
            SELECT u.*
            FROM users u
            INNER JOIN tenant_users tu ON u.id = tu.user_id
            WHERE tu.tenant_id = ? AND tu.is_primary is true
            SQL
        my $user_data = $db->query( $sql, $id )->expand->hash;
        return unless $user_data && $user_data->{id};
        return Registry::DAO::User->new( $user_data->%* );
    }

    method users ($db) {

        # TODO: this should be a join
        $db->select( 'tenant_users', '*', { tenant_id => $id } )
          ->hashes->map(
            sub { Registry::DAO::User->find( $db, { id => $_->{user_id} } ) } )
          ->to_array->@*;
    }

    method set_primary_user ( $db, $user ) {
        $db->insert(
            'tenant_users',
            {
                tenant_id  => $id,
                user_id    => $user->id,
                is_primary => 1
            },
            {
                on_conflict => [
                    [ 'tenant_id', 'user_id' ] => { is_primary => 1 }
                ]
            }
        );
    }

    method add_user ( $db, $user, $is_primary = 0 ) {
        Carp::croak 'user must be a Registry::DAO::User'
          unless $user isa Registry::DAO::User;
        $db->insert(
            'tenant_users',
            {
                tenant_id  => $id,
                user_id    => $user->id,
                is_primary => $is_primary ? 1 : 0
            },
            { returning => '*' }
        );
    }

    method update_canonical_domain ($db, $domain) {
        $db = $db->db if $db isa Registry::DAO;
        return $self->update($db, { canonical_domain => $domain });
    }

    # A tenant can take paid enrollment only when its connected account exists
    # and Stripe reports it ready to take charges with onboarding complete.
    method stripe_connect_ready {
        return $stripe_connect_account_id
            && $stripe_charges_enabled
            && $stripe_details_submitted ? 1 : 0;
    }

    method slug_exists :common ($db, $slug) {
        my $result = $db->query('SELECT COUNT(*) FROM registry.tenants WHERE slug = ?', $slug);
        return $result->array->[0] > 0;
    }

    # Get all tenant schemas for background jobs
    sub get_all_tenant_schemas($class, $db) {
        return $db->select('registry.tenants', ['slug'])->hashes->to_array;
    }

    # provision: single canonical path for creating a fully-provisioned tenant.
    # Creates the tenant row, clones the schema, copies seed data, copies all
    # workflows from registry (except tenant-signup), copies users, and copies
    # OutcomeDefinitions.  The entire operation runs inside a single transaction
    # so a failure partway through does not leave orphaned rows or a half-cloned
    # schema.  Returns the created Tenant object.
    #
    # $data must contain: name (required), slug (optional), users (arrayref of
    # Registry::DAO::User objects or hashrefs with {id}).
    sub provision($class, $db, $data) {
        my $users    = delete $data->{users} // [];
        $data->{slug} //= lc( $data->{name} =~ s/\s+/_/gr );

        # Normalize slug for use as a PostgreSQL schema name.  clone_schema
        # does not quote the dest_schema in all its EXECUTE statements, so
        # identifiers that would require quoting (e.g. those containing '-')
        # produce syntax errors.  Hyphens are replaced with underscores so
        # the slug is a safe unquoted PostgreSQL identifier.
        $data->{slug} =~ s/-/_/g;

        # Filter to only the columns that exist in the tenants table.
        # Callers may pass a full profile hash; extra keys (billing_*, admin_*,
        # subscription, etc.) must not reach the INSERT.
        my %TENANT_COLUMNS = map { $_ => 1 } qw(
            name slug canonical_domain stripe_subscription_id
            billing_status trial_ends_at subscription_started_at
            magic_link_expiry_hours
            stripe_connect_account_id stripe_charges_enabled stripe_details_submitted
            platform_pricing_plan_id
        );
        my %tenant_data = map { $_ => $data->{$_} }
                          grep { exists $TENANT_COLUMNS{$_} } keys %$data;

        # Begin the transaction before any writes so that tenant row creation,
        # schema cloning, and all subsequent copies are atomic.  Postgres allows
        # CREATE SCHEMA (issued inside clone_schema) within a transaction.
        my $tx = $db->begin;

        my $tenant = $class->create($db, \%tenant_data);
        $db->query('SELECT clone_schema(?)', $tenant->slug);

        # clone_schema changes the connection's search_path to the new schema
        # when run inside a transaction.  Reset it to registry so subsequent
        # queries (User->find, set_primary_user, etc.) resolve against the
        # correct schema.
        $db->query('SET search_path = registry, public');

        # Quote the slug as a PostgreSQL identifier once and reuse throughout.
        # quote_identifier wraps the name in double-quotes, which is valid in
        # both "schema".table and SET search_path = "schema", public contexts.
        # This handles slugs that are PostgreSQL reserved words (e.g. "user",
        # "order") that would otherwise cause syntax errors when interpolated
        # unquoted into DDL or SET statements.
        my $schema = $db->dbh->quote_identifier($tenant->slug);

        # Copy seed data that clone_schema does not include (structure only, no rows)
        $db->query(qq{
            INSERT INTO ${schema}.program_types (slug, name, config, created_at, updated_at)
            SELECT slug, name, config, created_at, updated_at
            FROM registry.program_types
            ON CONFLICT (slug) DO NOTHING
        });

        # NOTE: Templates are copied per-workflow by copy_workflow (which creates
        # new template rows linked to the tenant's workflow steps).  A bulk copy
        # here would conflict with copy_workflow's template inserts because both
        # the tenant schema and copy_workflow use the same unique-constrained name
        # column, and copy_workflow does not use ON CONFLICT.

        # Set the first user as primary
        if (@$users) {
            my $first = $users->[0];
            my $first_id = ref $first eq 'HASH' ? $first->{id} : $first->id;
            my ($primary_user) = Registry::DAO::User->find($db, { id => $first_id });
            $tenant->set_primary_user($db, $primary_user) if $primary_user;
        }

        # Copy each supplied user into the tenant schema
        for my $user (@$users) {
            my $user_id = ref $user eq 'HASH' ? $user->{id} : $user->id;
            $db->query('SELECT copy_user(dest_schema => ?, user_id => ?)',
                $tenant->slug, $user_id);
        }

        # Copy OutcomeDefinitions into the tenant schema BEFORE copying workflows.
        # copy_workflow inserts workflow_steps with outcome_definition_id FK values;
        # the tenant schema's workflow_steps FK references the tenant's own
        # outcome_definitions table (clone_schema strips the schema qualifier).
        # Copying outcome definitions here ensures the FK is satisfiable when
        # copy_workflow runs below.  We temporarily switch the search_path on $db
        # so unqualified 'outcome_definitions' resolves to the tenant schema.
        # After the inserts we reset to registry so later queries remain correct.
        my @outcome_defs = Registry::DAO::OutcomeDefinition->find($db);
        if (@outcome_defs) {
            $db->query("SET search_path = ${schema}, public");
            for my $def (@outcome_defs) {
                Registry::DAO::OutcomeDefinition->create(
                    $db,
                    {
                        id     => $def->id,
                        name   => $def->name,
                        schema => $def->schema,
                    }
                );
            }
            $db->query('SET search_path = registry, public');
        }

        # Copy every workflow in registry except tenant-signup
        my @workflows = $db->select('registry.workflows', ['id', 'slug'])->hashes->each;
        for my $wf (@workflows) {
            next if $wf->{slug} eq 'tenant-signup';
            $db->query('SELECT copy_workflow(dest_schema => ?, workflow_id => ?)',
                $tenant->slug, $wf->{id});
        }

        # The registry schema holds a DB template named 'tenant-storefront/program-listing'
        # containing the REGISTRY marketing page ("Your art deserves a real business").
        # copy_workflow copied it into the tenant schema because the program-listing
        # workflow step's template_id pointed to it.  DBTemplates resolves DB templates
        # before the filesystem, so tenants would serve the marketing page instead of
        # the program catalog (templates/tenant-storefront/program-listing.html.ep).
        # Fix: NULL the step's template_id and delete the template from the tenant
        # schema so DBTemplates falls back to the correct filesystem catalog.
        # (refs #173 #229)
        $db->query(qq{
            UPDATE ${schema}.workflow_steps ws
               SET template_id = NULL
              FROM ${schema}.workflows wf, ${schema}.templates tpl
             WHERE wf.slug = 'tenant-storefront'
               AND ws.workflow_id = wf.id
               AND ws.slug = 'program-listing'
               AND ws.template_id = tpl.id
               AND tpl.name = 'tenant-storefront/program-listing'
        });
        $db->query(qq{
            DELETE FROM ${schema}.templates
             WHERE name = 'tenant-storefront/program-listing'
        });

        $tx->commit;

        return $tenant;
    }
}