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
    field $slug :param :reader //= __PACKAGE__->slug_for_name($name);
    field $created_at :param :reader;
    field $canonical_domain :param :reader = undef;
    # Mirrors tenants.magic_link_expiry_hours, whose default moved to one hour in
    # #450. Only reached for a Tenant built without the column.
    field $magic_link_expiry_hours :param :reader = 1;
    field $stripe_connect_account_id :param :reader = undef;
    field $stripe_charges_enabled    :param :reader = 0;
    field $stripe_details_submitted  :param :reader = 0;

    sub table { 'tenants' }

    # A slug is a PostgreSQL schema name, a DNS label, and a routing key, and
    # all three want the same shape.
    #
    # clone_schema does `set_config('search_path', dest_schema, true)` on the
    # UNQUOTED name while quoting it elsewhere, so a mixed-case slug case-folds
    # in one half of a statement and not the other -- it dies partway through
    # and leaves a half-built schema. Hyphens are worse still: not every
    # EXECUTE in there quotes the name, so they are syntax errors.
    #
    # Routing already assumes the normalised form regardless.
    # _extract_tenant_from_subdomain lowercases the Host header, and the tenant
    # helper's own regex is /\A[a-z][a-z0-9_]{0,62}\z/ -- so a mixed-case
    # tenant could never have been reached even had clone_schema built it.
    sub normalize_slug ( $class, $slug ) {
        return $slug unless defined $slug;
        return lc($slug) =~ s/-/_/gr;
    }

    # Subdomains the platform keeps for itself, or that Postgres will not lend.
    #
    # A slug is three things at once, and each of them can be squatted:
    #
    #   www         Registry.pm's _extract_tenant_from_subdomain returns undef
    #               for it explicitly, so a tenant provisioned as www could
    #               never be reached at its own URL. Inert by construction, and
    #               holding the name forever.
    #   registry    the platform schema. clone_schema would be asked to build a
    #               tenant on top of the thing it copies FROM.
    #   public,     Postgres' own. A schema here fails to build, if we are lucky
    #   pg_*        loudly.
    #   the rest    hostnames the platform may need to serve from. A tenant on
    #               `api` or `status` shadows any future use of that name, and
    #               taking it back means moving somebody's live studio.
    #
    # This is a squatting fix (#443) but it is also a routing one: the first two
    # are hazards today, not merely inconveniences later.
    my %RESERVED_SLUGS = map { $_ => 1 } qw(
        www registry public admin api app assets billing blog cdn dashboard dev
        docs ftp help imap mail mx ns ns1 ns2 platform pop pop3 smtp staging
        static status support test webmail
    );

    sub slug_is_reserved ( $class, $slug ) {
        return 0 unless defined $slug;
        my $s = lc $slug;
        return 1 if $RESERVED_SLUGS{$s};

        # pg_catalog, pg_toast, pg_temp_1 and every other reserved prefix
        # Postgres refuses to let anybody create.
        return 1 if $s =~ /^pg_/;

        return 0;
    }

    # Derive a slug from an organisation name. The single place that does this.
    #
    # There used to be three, and they disagreed: the profile page's live
    # preview and Workflows::_generate_subdomain_slug both stripped punctuation
    # and joined with hyphens, while provision only replaced whitespace. So
    # "Clay & Kiln Studio" was previewed as clay-kiln-studio, told the applicant
    # it was Available, and then provisioned as clay_&_kiln_studio -- a schema
    # name and a hostname containing an ampersand. The tenant helper's routing
    # regex is /\A[a-z][a-z0-9_]{0,62}\z/, so that studio could never have been
    # reached at the URL its own confirmation page handed it.
    #
    # Underscores rather than hyphens because this is also an unquoted schema
    # name in clone_schema; see normalize_slug above.
    sub slug_for_name ( $class, $name ) {
        my $slug = lc( $name // '' );
        $slug =~ s/[^a-z0-9]+/_/g;
        $slug =~ s/^_+|_+$//g;
        $slug = substr( $slug, 0, 63 );
        $slug =~ s/_+$//;
        return length($slug) ? $slug : 'organization';
    }

    # The same slug, plus whatever suffix it takes to be free. The signup page
    # tells an applicant their subdomain is "Available" before they commit, so
    # the check and the INSERT have to agree about which name that is --
    # otherwise the preview offers name_1 and provisioning still tries name and
    # dies on tenants_slug_key.
    #
    # Only for a DERIVED slug. A caller who names a slug gets the one they
    # named, or the unique-index error; quietly provisioning someone into
    # acme_1 when they asked for acme would be worse than failing.
    sub available_slug_for_name ( $class, $db, $name ) {
        my $base = $class->slug_for_name($name);
        my $slug = $base;
        my $n    = 1;
        # Reserved counts as taken. An organisation actually called "API"
        # derives exactly the reserved word, and the derivation is where that
        # has to be caught -- provision takes whatever it is handed.
        while ( $class->slug_exists( $db, $slug ) || $class->slug_is_reserved($slug) ) {
            $slug = "${base}_${n}";
            last if ++$n > 999;
        }
        return $slug;
    }

    # create does NOT normalise a supplied slug, deliberately. Rewriting a value
    # the caller chose breaks find-then-create: t/playwright/setup_registration_test_data.pl
    # searches for 'super-awesome-cool-pottery' and creates with the same
    # string, so silently storing 'super_awesome_cool_pottery' meant find never
    # matched its own row and the second run inserted a duplicate. Three specs
    # share that seed; the e2e suite caught it.
    #
    # Normalisation belongs where a schema name is actually derived -- provision
    # -- and the tenants_slug_is_lowercase constraint refuses the unsafe case
    # outright rather than quietly changing it.
    sub create ( $class, $db, $data ) {
        $data->{slug} //= $class->slug_for_name( $data->{name} );
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

    # Which tenant is the platform itself.
    #
    # One owner for the question, because "is this Alex" is about to be asked
    # from more than one place and #294 wants to collapse `registry-platform`
    # into `registry` -- when that happens, this method changes and nothing else
    # does.
    #
    # The notion is not new: create-default-pricing-relationships.sql has
    # treated the all-zeros tenant as the platform since it was written, and
    # production carries it as slug `registry-platform` with exactly one primary
    # user. Resolved by slug rather than by that literal uuid, because a slug is
    # what the rest of the system routes and reasons about.
    sub platform ($class, $db) {
        $db = $db->db if $db isa Registry::DAO;
        return $class->find( $db, { slug => 'registry-platform' } );
    }

    # Is this user the platform's owner?
    #
    # Platform-ness is being the PRIMARY user of the platform tenant, not a
    # user_type: `check_user_type` caps that column at parent/student/staff/admin,
    # and Morgan running a studio is every bit as much an 'admin' as Alex. The
    # distinction the product needs is which tenant you are primary of.
    sub is_platform_admin ($class, $db, $user_id) {
        $db = $db->db if $db isa Registry::DAO;
        return 0 unless defined $user_id && !ref $user_id && length $user_id;

        my $platform = $class->platform($db) or return 0;

        # Asked of the join table rather than through primary_user, which
        # returns the first of however many rows carry is_primary -- add_user
        # does not enforce one. An auth decision should not depend on which row
        # a LIMIT-less query happened to return first, and "is A primary of the
        # platform" is the question anyway.
        return $db->select( 'registry.tenant_users', 'COUNT(*)', {
            tenant_id  => $platform->id,
            user_id    => $user_id,
            is_primary => 1,
        } )->array->[0] ? 1 : 0;
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

    # Send a person their invitation: a magic link into this tenant.
    #
    # Lives here rather than on the signup step because signup must NOT send it.
    # Signup is anonymous, the team-member addresses on the form are whatever the
    # caller typed, and delivery is real now -- Postmark in production -- so
    # mailing them made an unauthenticated form into an outbound mailer for
    # attacker-chosen recipients, carrying our sending domain and a working
    # magic link (#438). #289 predicted this would become real "the day that
    # TODO is implemented"; it has. The admin sends invitations after signing
    # in, which is itself proof they hold the address the tenant was created
    # with.
    #
    # Returns 1 on success, 0 on failure. Best effort by contract: a caller
    # provisioning a tenant must not have it rolled back by an undeliverable
    # invitation, and a caller clicking a button wants to be told, not 500'd.
    method invite_user ( $db, $user, $inviter_name = '' ) {
        require Registry::DAO::MagicLinkToken;
        require Registry::DAO::Notification;
        require Registry::Utility::BaseDomain;

        # On this tenant's own handle, not the caller's. $user is a row in
        # <slug>.users, so a token minted against registry would carry a user_id
        # that exists in neither schema's terms: unresolvable from the apex,
        # because the user is not there, and unresolvable from the subdomain,
        # because the token is not. The pairing has to hold on both sides.
        my $tenant_db = $self->dao($db)->db;

        my $ok = eval {
            my ( $token, $plaintext ) = Registry::DAO::MagicLinkToken->generate(
                $tenant_db,
                { user_id => $user->id, purpose => 'invite', expires_in => 168 },
            );

            # And the link goes to this tenant's own host, where $c->dao resolves
            # to the schema the token and the user both live in.
            my $base_url = Registry::Utility::BaseDomain::tenant_url($slug);

            # Sent the way AccountCheck sends a login link: a notification
            # carrying the URL, rendered by the magic_link_invite template.
            # Auth.pm already routes an invite token to passkey registration
            # rather than the homepage, which is what someone arriving without
            # an account needs.
            my $notification = Registry::DAO::Notification->create( $tenant_db, {
                user_id  => $user->id,
                type     => 'magic_link_invite',
                channel  => 'email',
                subject  => sprintf( 'You have been invited to %s', $name ),
                message  => sprintf( 'Invitation to %s for %s',
                    $name, $user->email // $user->username ),
                metadata => {
                    tenant_name      => $name,
                    inviter_name     => $inviter_name,
                    role             => $user->user_type // 'staff',
                    magic_link_url   => "$base_url/auth/magic/$plaintext",
                    expires_in_hours => 168,
                },
            } );

            $notification->send($tenant_db);
            1;
        };

        unless ($ok) {
            warn "invitation email to " . ( $user->email // $user->username )
               . " for tenant $slug failed: $@";
            return 0;
        }

        $user->mark_invited($tenant_db);
        return 1;
    }

    # How long a tenant may sit unused before anybody calls it abandoned, or undef
    # when the platform never does.
    #
    # Ninety days by default -- perigrin's number, and a decision rather than a
    # round one: a studio that signs up before a school year and opens in
    # September would be reclaimed by an impatient window, and reclaiming means
    # dropping a schema.
    #
    # How long a tenant may sit unused before anybody calls it abandoned, or undef
    # when the platform never does.
    #
    # Three states, and they are not two (perigrin):
    #
    #   NULL  ->  90       not set: the platform has no opinion, the default stands
    #   0     ->  undef    never: no tenant is ever considered inert
    #   N     ->  N        N days
    #
    # Keeping "not set" and 0 apart is the whole point. Collapsing them either
    # way is a bug with teeth: NULL reading as never silently switches off a
    # report an operator thinks is running, and 0 reading as NULL switches on a
    # 90-day window somebody explicitly turned off. It is why
    # platform_settings.value is nullable and says so in a COMMENT.
    #
    # A row rather than an env var, because Alex should be able to see and change
    # it without a deploy -- which is Pillar 5 of PriceOps, and the part #427
    # measures as absent.
    #
    # Junk falls back to the default rather than to 0, for the same reason in the
    # other direction: a value nobody can parse should not land on either
    # extreme, and this report is the input to a deletion.
    sub inert_after_days ( $class, $db ) {
        require Registry::DAO::PlatformSetting;
        my $raw = Registry::DAO::PlatformSetting->get( $db, 'inert_tenant_days' );

        # NULL, and whitespace-as-NULL: a row somebody blanked is somebody
        # having no opinion, not somebody choosing never.
        return 90 unless defined $raw && $raw =~ /\S/;

        my $v = lc $raw;
        $v =~ s/^\s+|\s+$//g;

        # 0 is never. The words are accepted too, because "never" is what a
        # person types when a form asks them, and refusing it would make the
        # setting a puzzle.
        return undef if $v =~ /\A(?: 0 | never | off | none | no )\z/x;

        return 0 + $v if $v =~ /\A[1-9][0-9]*\z/;

        return 90;
    }

    # Tenants nobody has ever signed into, older than the configured window.
    #
    # An inert tenant holds its subdomain exactly as firmly as a real one, and
    # nothing releases it (#443). This finds the candidates; it does not act on
    # them, deliberately. Freeing a slug means dropping a schema, which is
    # irreversible and is a decision for a person -- an automatic reaper that got
    # the predicate slightly wrong would delete a studio.
    #
    # "Never signed into" is answerable because there is no password login: the
    # first way into any tenant is a magic link, so a tenant whose
    # magic_link_tokens table holds no consumed row has never been entered.
    # Registering a passkey needs an authenticated session, so it cannot be the
    # first way in and cannot hide a login from this.
    sub inert ( $class, $db, %opt ) {
        $db = $db->db if $db isa Registry::DAO;

        # A caller naming a window gets it, even when reclaiming is switched off:
        # the CLI's argument is for looking, and looking is not reclaiming.
        my $days = $opt{older_than_days} // $class->inert_after_days($db);

        # Switched off is reported as switched off, never as an empty list. The
        # two look identical to anyone reading output, and an operator who acted
        # on "found nothing" would be wrong about "not looking".
        return { enabled => 0, window_days => undef, tenants => [] }
            unless defined $days;

        my @inert;
        for my $row ( $db->query( q{
            SELECT id, name, slug, created_at
              FROM registry.tenants
             WHERE slug <> 'registry'
               AND created_at < now() - ($1 || ' days')::interval
             ORDER BY created_at
        }, $days )->hashes->each )
        {
            # A schema that is not there cannot be entered either, and a
            # half-provisioned one is its own problem (#330) rather than this
            # one -- so it is reported rather than skipped.
            my $tokens = to_regclass_exists( $db, $row->{slug}, 'magic_link_tokens' );
            unless ($tokens) {
                push @inert, { %$row, reason => 'no magic_link_tokens table' };
                next;
            }

            my $used = $db->query( sprintf(
                'SELECT count(*) FROM %s.magic_link_tokens WHERE consumed_at IS NOT NULL',
                $db->dbh->quote_identifier( $row->{slug} ) ) )->array->[0];

            push @inert, { %$row, reason => 'never signed into' } unless $used;
        }

        return { enabled => 1, window_days => $days, tenants => \@inert };
    }

    sub to_regclass_exists ( $db, $schema, $table ) {
        return $db->query( 'SELECT to_regclass(?) IS NOT NULL AS ok',
            "$schema.$table" )->hash->{ok} ? 1 : 0;
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

        # Normalised here as well as in create, because the value is used for
        # clone_schema below before create is ever reached. Previously the
        # lowercasing applied only when the slug was DERIVED from the name, so
        # a slug supplied through signup kept its capitals all the way into
        # clone_schema.
        $data->{slug} //= $class->available_slug_for_name( $db, $data->{name} );
        $data->{slug} = $class->normalize_slug( $data->{slug} );

        # available_slug_for_name only guards the DERIVED path; a caller naming
        # a slug gets the one they named, deliberately. So the refusal belongs
        # here, the last point before clone_schema builds a schema that shadows
        # the platform's own hostname -- or, for 'registry', builds a tenant on
        # top of the schema it is copying from.
        Carp::croak "'$data->{slug}' is a reserved subdomain and cannot be a tenant"
            if $class->slug_is_reserved( $data->{slug} );

        # Filter to only the columns that exist in the tenants table.
        # Callers may pass a full profile hash; extra keys (billing_*, admin_*,
        # subscription, etc.) must not reach the INSERT.
        my %TENANT_COLUMNS = map { $_ => 1 } qw(
            name slug canonical_domain stripe_subscription_id
            billing_status trial_ends_at subscription_started_at
            magic_link_expiry_hours
            stripe_connect_account_id stripe_charges_enabled stripe_details_submitted
            platform_pricing_plan_id created_from_ip
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
            # tenant-signup onboards tenants; registry-storefront is the
            # platform's own shop window. Handing either to a tenant is the
            # mirror of the bug that made the apex serve a tenant's storefront.
            next if $wf->{slug} eq 'tenant-signup';
            next if $wf->{slug} eq 'registry-storefront';
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