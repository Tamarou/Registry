# ABOUTME: DAO for tenant organizations. Manages tenant creation, schema
# ABOUTME: isolation, user association, and domain configuration.
use 5.42.0;
use Object::Pad;

class Registry::DAO::Tenant :isa(Registry::DAO::Object) {
    use Registry::DAO::Workflow;
    use Registry::DAO::OutcomeDefinition;
    use Registry::DAO;
    use Registry::DAO::Payment;
    use Registry::DAO::Entitlement;
    use Registry::PriceOps::PlatformTerms ();
    use Registry::WorkflowDivergence ();
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

    # registry.tenants is the directory. clone_schema gives every tenant schema
    # an empty copy of this table, and a tenant connection searches its own
    # schema first, so an unqualified name read and wrote that copy instead.
    sub table { 'registry.tenants' }

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
    #
    # registry-platform is the platform's retired second row (collapse-platform-
    # tenant). Held in both spellings, since provision turns the hyphen into an
    # underscore, so nothing that still remembers the name can find a studio.
    my %RESERVED_SLUGS = map { $_ => 1 } qw(
        www registry public admin api app assets billing blog cdn dashboard dev
        docs ftp help imap mail mx ns ns1 ns2 platform pop pop3 smtp staging
        static status support test webmail
        registry-platform registry_platform
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
    # One owner for the question, because "is this Alex" is asked from more
    # than one place.
    #
    # The platform tenant is `registry`: the all-zeros row that
    # create-default-pricing-relationships.sql has treated as the platform since
    # it was written, which collapse-platform-tenant.sql renamed from
    # `registry-platform` when it folded the old `registry` row into it. It owns
    # the `registry` schema and has exactly one primary user. Resolved by slug
    # rather than by that literal uuid, because a slug is what the rest of the
    # system routes and reasons about.
    sub platform ($class, $db) {
        $db = $db->db if $db isa Registry::DAO;
        return $class->find( $db, { slug => 'registry' } );
    }

    # Write Tamarou's Stripe account and readiness onto the platform row, and
    # the address of its first admin onto that admin's profile, from
    # deployment configuration, the way STRIPE_SECRET_KEY reaches the app.
    #
    # The migrations create the row and an admin whose address nobody
    # receives; a migration runs once and cannot read the container's
    # environment, so `registry platform bootstrap` calls this on every start
    # (ADR 005, ruling 5). $config is keyed by the variable names so whatever
    # is wrong with it can be reported by the name an operator sets.
    #
    # Dies, writing nothing, when a value is missing or malformed, when the
    # admin address already belongs to anyone but the platform's admin, or
    # when there is no platform row: everything is checked before anything is
    # written. Returns the platform tenant, and in list context a second
    # value: why the row was kept, when it already names a different account.
    # That account is one an admin has chosen since, and the ruling is that
    # bootstrap never overwrites it.
    my %READY_VALUE = (
        ( map { $_ => 1 } qw( 1 true yes on ) ),
        ( map { $_ => 0 } qw( 0 false no off ) ),
    );

    my $UNCHANGED = " -- the platform tenant and its admin were left as they are\n";

    # The values bootstrap_platform is given, judged on their own: the checks
    # that need no database. Dies naming the first problem; returns the
    # account id, readiness (1 or 0) and admin email. The entrypoint runs it,
    # through `registry platform check`, before migrating, so a configuration
    # bootstrap would refuse stops the boot while the schema still matches the
    # code already serving.
    sub check_platform_config ( $class, $config ) {
        my @missing = grep { !defined $config->{$_} }
            qw( PLATFORM_STRIPE_ACCOUNT_ID PLATFORM_STRIPE_READY PLATFORM_ADMIN_EMAIL );
        die 'Not set: ' . join( ', ', @missing ) . $UNCHANGED
          if @missing;

        my $account = $config->{PLATFORM_STRIPE_ACCOUNT_ID};
        die "PLATFORM_STRIPE_ACCOUNT_ID '$account' is not a Stripe account id (acct_...)"
          . $UNCHANGED
          unless $account =~ /\Aacct_\w+\z/a;

        my $ready = $READY_VALUE{ lc $config->{PLATFORM_STRIPE_READY} };
        die "PLATFORM_STRIPE_READY '$config->{PLATFORM_STRIPE_READY}' is not true or false"
          . $UNCHANGED
          unless defined $ready;

        # One address and nothing else: no whitespace or control characters,
        # so a value carrying a newline cannot smuggle a header (Bcc: ...)
        # into the mail sent to it.
        my $email = $config->{PLATFORM_ADMIN_EMAIL};
        unless ( length $email <= 255
            && $email =~ /\A[^\s\@[:cntrl:]]+\@[^\s\@[:cntrl:]]+\z/ )
        {
            ( my $shown = $email ) =~ s/([[:cntrl:]])/sprintf '\\x%02x', ord $1/ge;
            die "PLATFORM_ADMIN_EMAIL '$shown' is not a single email address" . $UNCHANGED;
        }

        return ( $account, $ready, $email );
    }

    sub bootstrap_platform ( $class, $db, $config ) {
        $db = $db->db if $db isa Registry::DAO;

        my ( $account, $ready, $email ) = $class->check_platform_config($config);

        my $platform = $class->platform($db)
            or die "There is no platform tenant (slug 'registry') to bootstrap;"
                 . " deploy the schema first. No tenant was created.\n";

        # The platform's primary admin. A primary member who is not admin-role
        # is not it, and is never promoted: with no admin-role member at all a
        # new admin is created. An admin-role member who is not primary still
        # counts, so a second admin is never made beside one.
        my $admin = $db->query( q{
            SELECT tu.user_id, up.email
              FROM registry.tenant_users tu
              LEFT JOIN registry.user_profiles up ON up.user_id = tu.user_id
             WHERE tu.tenant_id = ? AND tu.role = 'admin'
             ORDER BY tu.is_primary DESC, tu.created_at, tu.user_id
             LIMIT 1
        }, $platform->id )->hash;

        # An address someone else signs in with -- a studio's user, say -- is
        # not taken over: that would hand them the platform, or the platform
        # their account. Compared without case, as mail delivery does.
        die "PLATFORM_ADMIN_EMAIL '$email' is already in use by another user" . $UNCHANGED
          if $db->query( q{
                SELECT 1 FROM registry.user_profiles
                 WHERE lower(email) = lower(?) AND user_id IS DISTINCT FROM ?
            }, $email, $admin && $admin->{user_id} )->rows;

        if ( !$admin ) {
            my $user = Registry::DAO::User->create( $db, {
                username  => $email,
                user_type => 'admin',
                email     => $email,
                name      => 'Platform Admin',
            } );
            $platform->add_user( $db, $user, 1, 'admin' );
        }
        elsif ( ( $admin->{email} // '' ) ne $email ) {
            $db->insert( 'registry.user_profiles',
                { user_id => $admin->{user_id}, email => $email, name => 'Platform Admin' },
                { on_conflict => [ user_id => { email => $email } ] } );
        }

        my $recorded = $platform->stripe_connect_account_id;
        if ( defined $recorded && $recorded ne $account ) {
            return wantarray
              ? ( $platform, "The platform tenant already records Stripe account $recorded;"
                  . " PLATFORM_STRIPE_ACCOUNT_ID is $account. Kept $recorded and its readiness as they were." )
              : $platform;
        }

        # Runs on every start, so a row already saying this is left untouched
        # rather than rewritten with the same values.
        return $platform
          if ( $platform->stripe_connect_account_id // '' ) eq $account
          && !!$platform->stripe_charges_enabled   == !!$ready
          && !!$platform->stripe_details_submitted == !!$ready;

        return $platform->update( $db, {
            stripe_connect_account_id => $account,
            stripe_charges_enabled    => $ready,
            stripe_details_submitted  => $ready,
        } );
    }

    # Is this user an admin of the platform?
    #
    # Platform-ness is a membership of the platform tenant whose role is
    # 'admin', primary or not. Not a user_type: `check_user_type` caps that
    # column at parent/student/staff/admin, and Morgan running a studio is every
    # bit as much an 'admin' as Alex. The distinction the product needs is which
    # tenant you are an admin member of.
    sub is_platform_admin ($class, $db, $user_id) {
        $db = $db->db if $db isa Registry::DAO;
        return 0 unless defined $user_id && !ref $user_id && length $user_id;

        my $platform = $class->platform($db) or return 0;

        # The membership's role, not users.user_type: that column is global,
        # so a studio's admin added to the platform as support would otherwise
        # be a platform admin (ADR 005, ruling 4).
        return $db->select( 'registry.tenant_users', 'COUNT(*)', {
            tenant_id => $platform->id,
            user_id   => $user_id,
            role      => 'admin',
        } )->array->[0] ? 1 : 0;
    }

    # What role does $user_id have in the tenant whose slug is $slug?
    #
    # The membership's role for that tenant (ADR 005, ruling 4), never the
    # global users.user_type: an admin of one tenant is whatever their
    # membership says in another, and nothing at all where they have none.
    #
    # One exception, because it cannot hold a membership: an account that
    # exists only in the tenant's own schema -- a parent who registered at the
    # tenant's storefront, staff the tenant created -- has no registry.users row
    # for tenant_users.user_id to reference. That row is the tenant's own record
    # of them, per tenant by construction, so its user_type is their role there
    # and nowhere else.
    # A workflow just created $user in the tenant whose schema is $slug (the
    # handle's current schema by default). Authority there is the membership
    # role, so a registry account is made a member in its own role. An account
    # local to a studio's schema cannot hold a membership (tenant_users.user_id
    # references registry.users) and keeps its local role; nothing to do.
    sub admit_new_account ($class, $db, $user, $slug = undef) {
        $db = $db->db if $db isa Registry::DAO;
        $slug //= $db->query('SELECT current_schema()')->array->[0];
        return unless $db->select( 'registry.users', 'COUNT(*)', { id => $user->id } )->array->[0];
        my $tenant = $class->find( $db, { slug => $slug } ) or return;
        return if $db->select( 'registry.tenant_users', 'COUNT(*)',
            { tenant_id => $tenant->id, user_id => $user->id } )->array->[0];
        $tenant->add_user( $db, $user, 0, $user->user_type );
        return;
    }

    sub role_in ($class, $db, $slug, $user_id) {
        $db = $db->db if $db isa Registry::DAO;
        return undef unless defined $user_id && !ref $user_id && length $user_id;
        return undef unless defined $slug && $slug =~ /\A[a-z][a-z0-9_]{0,62}\z/;

        my $membership = $db->query( <<~'SQL', $slug, $user_id )->hash;
            SELECT tu.role
              FROM registry.tenant_users tu
              JOIN registry.tenants t ON t.id = tu.tenant_id
             WHERE t.slug = ? AND tu.user_id = ?
            SQL
        return $membership->{role} if $membership;

        return undef if $db->select( 'registry.users', 'COUNT(*)', { id => $user_id } )
                           ->array->[0];

        my $schema = $db->dbh->quote_identifier($slug);
        my $local  = eval {
            $db->query( "SELECT user_type FROM $schema.users WHERE id = ?", $user_id )->hash;
        };
        return $local ? $local->{user_type} : undef;
    }

    # Does tenant $tenant_id hold resource $resource?
    #
    # The one seam every caller asks, about the resource and never a plan or a
    # slug: the operator right is held by whichever tenant the data says holds
    # it, as an entitlement to the resource of that name in effect now.
    #
    # Qualified with registry: clone_schema gives every tenant schema its own
    # copy of the PriceOps tables, and an entitlement a tenant records in its
    # own copy grants nothing.
    sub holds ($class, $db, $tenant_id, $resource) {
        $db = $db->db if $db isa Registry::DAO;
        return 0 unless defined $tenant_id && length $tenant_id
                     && defined $resource  && length $resource;

        my $in_effect = Registry::DAO::Entitlement->in_effect_sql( 'e', q{tstzrange(now(), now(), '[]')} );
        return $db->query( qq{
            SELECT EXISTS (
                SELECT 1 FROM registry.entitlements e
                  JOIN registry.offer_versions v ON v.id = e.offer_version_id
                  JOIN registry.resources r      ON r.id = v.resource_id
                      OR r.id IN (SELECT s.resource_id FROM registry.offer_version_resources s
                                  WHERE s.offer_version_id = v.id)
                 WHERE e.holder_tenant_id = ? AND r.name = ? AND $in_effect)
        }, $tenant_id, $resource )->array->[0] ? 1 : 0;
    }

    # Does tenant $slug hold, in effect now, the unbounded resource named
    # $resource? Read from registry by name, as holds is: a tenant's cloned
    # entitlements are its own to write.
    sub holds_unbounded_by_slug ( $class, $db, $slug, $resource ) {
        my $in_effect = Registry::DAO::Entitlement->in_effect_sql( 'e', q{tstzrange(now(), now(), '[]')} );
        return $db->query( <<~"SQL", $slug, $resource )->array->[0];
            SELECT EXISTS (
                SELECT 1
                  FROM registry.entitlements e
                  JOIN registry.tenants t        ON t.id = e.holder_tenant_id
                  JOIN registry.offer_versions v ON v.id = e.offer_version_id
                  JOIN registry.resources r      ON r.id = v.resource_id
                      OR r.id IN (SELECT s.resource_id FROM registry.offer_version_resources s
                                  WHERE s.offer_version_id = v.id)
                 WHERE t.slug = ? AND r.name = ? AND r.kind = 'unbounded'
                   AND $in_effect
            )
            SQL
    }

    # Is $user_id an admin of some tenant that holds $resource?
    #
    # A right a tenant holds is usable by that tenant's admins: a membership
    # whose role is admin (ADR 005, ruling 4), never users.user_type. Whether
    # the tenant holds it is asked of holds, the one seam.
    sub admin_of_holder ($class, $db, $user_id, $resource) {
        $db = $db->db if $db isa Registry::DAO;
        return 0 unless defined $user_id && !ref $user_id && length $user_id;

        my $tenant_ids = $db->select( 'registry.tenant_users', 'tenant_id', {
            user_id => $user_id,
            role    => 'admin',
        } )->arrays->map( sub { $_->[0] } );

        return ( grep { $class->holds( $db, $_, $resource ) } @$tenant_ids ) ? 1 : 0;
    }

    method primary_user ($db) {
        my $sql = <<~'SQL';
            SELECT u.*
            FROM registry.users u
            INNER JOIN registry.tenant_users tu ON u.id = tu.user_id
            WHERE tu.tenant_id = ? AND tu.is_primary is true
            SQL
        my $user_data = $db->query( $sql, $id )->expand->hash;
        return unless $user_data && $user_data->{id};
        return Registry::DAO::User->new( $user_data->%* );
    }

    # Memberships and the users they name live in registry, so these are
    # qualified: a tenant-scoped handle searches only its own schema and
    # public, where tenant_users and users are the tenant's clones.
    method users ($db) {
        $db->query(
            'SELECT u.* FROM registry.users u
               JOIN registry.tenant_users tu ON u.id = tu.user_id
              WHERE tu.tenant_id = ?', $id )
          ->expand->hashes->map( sub { Registry::DAO::User->new( $_->%* ) } )
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
    # The platform tenant is judged by the same rule: it is one row now, slug
    # registry, and an exemption by slug is the identity check #427 removes.

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
             WHERE created_at < now() - ($1 || ' days')::interval
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

    # A new membership takes the user's user_type as its role, as add_user's
    # does; an existing one keeps the role it has.
    method set_primary_user ( $db, $user ) {
        $db->insert(
            'registry.tenant_users',
            {
                tenant_id  => $id,
                user_id    => $user->id,
                is_primary => 1,
                role       => $user->user_type,
            },
            {
                on_conflict => [
                    [ 'tenant_id', 'user_id' ] => { is_primary => 1 }
                ]
            }
        );
    }

    # The membership role is this tenant's view of the user (ruling 4). It
    # defaults to the user's user_type, which is what every membership meant
    # before memberships had roles.
    method add_user ( $db, $user, $is_primary = 0, $role = undef ) {
        Carp::croak 'user must be a Registry::DAO::User'
          unless $user isa Registry::DAO::User;
        $db->insert(
            'registry.tenant_users',
            {
                tenant_id  => $id,
                user_id    => $user->id,
                is_primary => $is_primary ? 1 : 0,
                role       => $role // $user->user_type,
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

    # Every tenant, with what the platform's owner has to know about it.
    #
    # #426: "is this customer actually working" takes four psql checks per
    # tenant today -- the row, the schema, the imports, and whether the admin
    # user is resident in both schemas -- which is a direct tax on a 15-hour
    # week and the reason a half-provisioned tenant stays invisible until
    # somebody complains (#265).
    #
    # Per-tenant failures are CAUGHT, not raised. A screen that dies on the
    # first broken tenant says nothing about any of the others, which is exactly
    # the position psql leaves you in. The broken ones are the point.
    sub fleet ( $class, $db ) {
        $db = $db->db if $db isa Registry::DAO;

        my $rows = $db->query( <<~'SQL' )->hashes->to_array;
            SELECT t.id, t.slug, t.name, t.created_at, t.canonical_domain,
                   t.stripe_connect_account_id,
                   t.stripe_charges_enabled,
                   t.stripe_details_submitted,
                   EXISTS (
                       SELECT 1 FROM information_schema.schemata s
                        WHERE s.schema_name = t.slug
                   ) AS schema_present
              FROM registry.tenants t
             ORDER BY t.created_at
            SQL

        for my $row (@$rows) {
            my @problems;

            # shortcut: one resolver call per tenant, fine for a handful of tenants; batch it when the fleet grows.
            $row->{plan_name} = eval {
                Registry::PriceOps::PlatformTerms::platform_terms_for_tenant( $db, $row->{slug} )->{name};
            };
            if ( my $err = $@ ) {
                $err =~ s/\s+/ /g;
                push @problems, "platform terms are unreadable: $err";
            }

            unless ( $row->{schema_present} ) {
                push @problems, 'schema was never created';
                $row->{problems} = \@problems;
                $row->{healthy}  = 0;
                next;
            }

            # Quoted, not interpolated. Slugs are constrained on the way in, and
            # a schema name reaching SQL unquoted is the kind of thing that stays
            # safe only as long as every writer of a slug keeps agreeing.
            my $schema = $db->dbh->quote_identifier( $row->{slug} );

            my $health = eval {
                $db->query( <<~"SQL", $row->{id} )->hash;
                    SELECT (SELECT COUNT(*) FROM $schema.workflows) AS workflows,
                           (SELECT COUNT(*) FROM $schema.templates) AS templates,
                           EXISTS (
                               SELECT 1
                                 FROM $schema.users su
                                 JOIN registry.tenant_users tu
                                      ON tu.user_id = su.id
                                WHERE tu.tenant_id = ? AND tu.is_primary
                           ) AS owner_resident
                    SQL
            };

            if ( my $err = $@ ) {
                # A schema that exists with its tables missing: worse than
                # absent, because every sweep and every page assumes otherwise.
                $err =~ s/\s+/ /g;
                push @problems, "schema is incomplete: $err";
                $row->{problems} = \@problems;
                $row->{healthy}  = 0;
                next;
            }

            $row->{health} = $health;

            push @problems, 'no workflows imported' unless $health->{workflows};
            push @problems, 'no templates imported' unless $health->{templates};
            push @problems, 'owner is not resident in the tenant schema'
              unless $health->{owner_resident};

            $row->{problems} = \@problems;
            $row->{healthy}  = @problems ? 0 : 1;
        }

        return $rows;
    }

    # What the platform has actually earned, per tenant and in total.
    #
    # Summed from payments.platform_fee_cents -- what Stripe reported taking --
    # and NEVER derived from amount x rate. A derived figure disagrees with the
    # charge on every rate change (#277), on every refund that returns the fee,
    # and wherever Stripe's rounding differs from ours, so it would be a number
    # that looks authoritative and is wrong.
    #
    # The consequence of recording rather than deriving is that charges made
    # before the column existed have no fee, and the honest thing is to say so.
    # `unrecorded` counts them, per tenant and overall, so the total reads as a
    # floor rather than a fact. A sum that silently omitted them would be the
    # same mistake in a quieter voice.
    sub platform_revenue ( $class, $db ) {
        $db = $db->db if $db isa Registry::DAO;

        # Charges live in the TENANT's schema, one table per tenant, because
        # `tenant-scoped-payments` moved payments out of registry and
        # Registry::DAO::Payment's SQL is unqualified throughout -- it contains
        # no reference to registry.payments at all. So this cannot be one join;
        # it is one query per tenant, the same shape as fleet() above.
        #
        # The platform tenant is one of them: registry.payments is its own
        # schema's table, holding its own sales, and its row shows the fees
        # recorded on them like any tenant's.
        my $tenants = $db->query( <<~'SQL' )->hashes->to_array;
            SELECT t.slug,
                   t.name,
                   EXISTS (
                       SELECT 1 FROM information_schema.schemata s
                        WHERE s.schema_name = t.slug
                   ) AS schema_present
              FROM registry.tenants t
             ORDER BY t.name
            SQL

        my ( $total, $unrecorded, @unreadable ) = ( 0, 0 );

        for my $row (@$tenants) {
            @{$row}{qw( charges fees_cents unrecorded )} = ( 0, 0, 0 );

            # shortcut: one resolver call per tenant, fine for a handful of tenants; batch it when the fleet grows.
            # Terms that will not resolve leave the plan blank rather than take the page down.
            if ( my $terms = eval {
                Registry::PriceOps::PlatformTerms::platform_terms_for_tenant( $db, $row->{slug} ) } )
            {
                @{$row}{qw( plan_name rate_pct )} = ( $terms->{name}, $terms->{fraction} * 100 );
            }

            # A tenant with no schema has no payments table to read. That is a
            # provisioning fault, and fleet() is the screen that reports it; here
            # it only means zero, not an error.
            next unless $row->{schema_present};

            # Quoted, not interpolated. Slugs are constrained on the way in, and
            # a schema name reaching SQL unquoted stays safe only as long as
            # every writer of a slug keeps agreeing.
            my $schema = $db->dbh->quote_identifier( $row->{slug} );

            # Every status in which money moved, refunds included: the platform
            # keeps its fee on a refund unless Stripe reports it returned, and
            # refund_pending is a captured charge whose fee is still held.
            my $c = eval {
                $db->query( <<~"SQL", Registry::DAO::Payment->_settled_statuses )->hash;
                    SELECT COUNT(*)                                  AS charges,
                           -- What the platform kept: each fee less what
                           -- Stripe reports returned (NULL is none), and
                           -- never below nothing.
                           COALESCE(SUM(GREATEST(platform_fee_cents
                               - COALESCE(platform_fee_refunded_cents, 0), 0)), 0)
                                                                     AS fees_cents,
                           COUNT(*) FILTER (
                               WHERE platform_fee_cents IS NULL )    AS unrecorded
                      FROM $schema.payments
                     WHERE status = ANY(?)
                    SQL
            };

            if ( my $err = $@ ) {
                # A schema present but unreadable must not be totalled as zero
                # and must not take the page down either. It is named, so the
                # total can be read as incomplete for a stated reason rather
                # than being quietly short.
                $err =~ s/\s+/ /g;
                push @unreadable, { slug => $row->{slug}, error => $err };
                $row->{unreadable} = $err;
                next;
            }

            @{$row}{qw( charges fees_cents unrecorded )} =
              @{$c}{qw( charges fees_cents unrecorded )};

            $total      += $c->{fees_cents} // 0;
            $unrecorded += $c->{unrecorded} // 0;
        }

        # Biggest earner first, as the old single query did.
        my @sorted = sort {
            ( $b->{fees_cents} // 0 ) <=> ( $a->{fees_cents} // 0 )
              or ( $a->{name} // '' ) cmp ( $b->{name} // '' )
        } @$tenants;

        return {
            tenants    => \@sorted,
            fees_cents => $total,
            unrecorded => $unrecorded,
            unreadable => \@unreadable,
        };
    }

    # Every payment with an unpaid obligation, across every tenant.
    #
    # record_capacity_obligation's own comment said it: "the runbook clears it
    # by hand; there is no automated reader". So a family could be demoted to
    # the waitlist, be owed their money back, and be visible nowhere -- the debt
    # was recorded correctly and then read by nothing.
    #
    # TWO kinds of row need a human, and they are not the same predicate:
    #
    #   refund_owed_cents > 0   money still owed. This column is what is LEFT
    #                           owed, not the original debt -- settling
    #                           decrements it -- so non-zero means outstanding.
    #
    #   status = 'refund_pending' with nothing computably owed. An unresolved
    #                           refund_manual_review flag deliberately holds the
    #                           row here (Payment.pm): a share this code could
    #                           not work out, which refunding the children it
    #                           COULD work out does not discharge. Payment.pm
    #                           states that the runbook finds these BY STATUS.
    #
    # Keying on the money alone would therefore miss precisely the rows nobody
    # has decided about, which are the ones most in need of a person. The
    # predicate is the union of both.
    sub unpaid_obligations ( $class, $db ) {
        $db = $db->db if $db isa Registry::DAO;

        # Payments live in the tenant's schema, so this is one query per tenant
        # rather than a join -- see platform_revenue above for why.
        my $tenants = $db->query( <<~'SQL' )->hashes->to_array;
            SELECT t.slug, t.name,
                   EXISTS (
                       SELECT 1 FROM information_schema.schemata s
                        WHERE s.schema_name = t.slug
                   ) AS schema_present
              FROM registry.tenants t
             ORDER BY t.name
            SQL

        # Declared separately on purpose: in a list assignment the first
        # array slurps the whole right-hand side.
        my @payments;
        my @unreadable;
        my $owed = 0;

        for my $row (@$tenants) {
            next unless $row->{schema_present};

            # Quoted, not interpolated; see fleet().
            my $schema = $db->dbh->quote_identifier( $row->{slug} );

            my $rows = eval {
                # The payer is named because the runbook's next action is to
                # contact a family, and an id is not a person.
                $db->query( <<~"SQL" )->hashes->to_array;
                    SELECT p.id            AS payment_id,
                           p.amount_cents,
                           p.refund_owed_cents,
                           p.refunded_cents,
                           p.status,
                           p.created_at,
                           -- name and email live on user_profiles, not users.
                           -- COALESCE to the username so a row whose profile
                           -- did not come across is still contactable rather
                           -- than appearing as a blank in the queue.
                           COALESCE(up.name, u.username) AS payer_name,
                           up.email                      AS payer_email,
                           COALESCE(jsonb_array_length(
                               p.metadata->'refund_manual_review'), 0)
                                           AS manual_review
                      FROM $schema.payments p
                      LEFT JOIN $schema.users u ON u.id = p.user_id
                      LEFT JOIN $schema.user_profiles up ON up.user_id = p.user_id
                     WHERE p.refund_owed_cents > 0
                        OR p.status = 'refund_pending'
                     ORDER BY p.created_at
                    SQL
            };

            if ( my $err = $@ ) {
                # Named rather than skipped. A runbook queue that quietly
                # omitted a tenant would read as "nothing to do", which is the
                # state this whole reader exists to stop being indistinguishable
                # from "nobody looked".
                $err =~ s/\s+/ /g;
                push @unreadable, { slug => $row->{slug}, error => $err };
                next;
            }

            for my $pay (@$rows) {
                $pay->{tenant_slug} = $row->{slug};
                $pay->{tenant_name} = $row->{name};
                $owed += $pay->{refund_owed_cents} // 0;
                push @payments, $pay;
            }
        }

        # Largest debt first; an undecided row sorts with the zero-owed rows and
        # is distinguished by manual_review, not by position.
        my @sorted = sort {
            ( $b->{refund_owed_cents} // 0 ) <=> ( $a->{refund_owed_cents} // 0 )
              or ( $a->{created_at} // '' ) cmp ( $b->{created_at} // '' )
        } @payments;

        return {
            payments   => \@sorted,
            owed_cents => $owed,
            unreadable => \@unreadable,
            undecided  => [ grep { $_->{manual_review} } @sorted ],
        };
    }

    # Every tenant but registry, by slug, as rows of slug and whether its
    # schema exists (present).
    sub slugs_with_schema_presence ( $class, $db ) {
        return $db->query(q{
            SELECT t.slug,
                   EXISTS ( SELECT 1 FROM pg_namespace n WHERE n.nspname = t.slug ) AS present
              FROM registry.tenants t
             WHERE t.slug <> 'registry'
             ORDER BY t.slug
        })->hashes->each;
    }

    # { id, slug } of the tenant whose Stripe Connect account is $account
    # (an exact, bound match), or undef.
    sub by_connect_account ( $class, $db, $account ) {
        return $db->select( 'registry.tenants', [ 'id', 'slug' ],
            { stripe_connect_account_id => $account } )->hash;
    }

    # Every tenant with a Stripe Connect account, as rows of slug and account.
    sub with_connect_account ( $class, $db ) {
        return $db->query( q{
            SELECT slug, stripe_connect_account_id AS account FROM registry.tenants
             WHERE stripe_connect_account_id IS NOT NULL
        } )->hashes;
    }

    # Mirrors Stripe's charges_enabled and details_submitted for $account
    # onto its tenant; an undef flag stays as it was. The number of rows changed.
    sub mirror_connect_readiness ( $class, $db, $account, $charges_enabled, $details_submitted ) {
        return $db->query(
            q{UPDATE registry.tenants
              SET stripe_charges_enabled   = COALESCE(?, stripe_charges_enabled),
                  stripe_details_submitted = COALESCE(?, stripe_details_submitted)
              WHERE stripe_connect_account_id = ?},
            $charges_enabled, $details_submitted, $account,
        )->rows;
    }

    # Points the search_path of $db's open transaction at schema $slug.
    # Transaction-local, so it reverts at COMMIT and cannot ride back into the
    # connection pool; bound, so Postgres validates the GUC rather than
    # splicing it into SQL text.
    sub use_schema_for_transaction ( $class, $db, $slug ) {
        $db->query( q{SELECT set_config('search_path', ?, true)}, "$slug, public" );
    }

    # Get all tenant schemas for background jobs
    sub get_all_tenant_schemas($class, $db) {
        return $db->select('registry.tenants', ['slug'])->hashes->to_array;
    }

    # Accepts the platform's offer $grant ({ offer_version_id, payment_plan_id })
    # for $tenant, and copies into $tenant's schema each registry workflow
    # whose run right (resource run:<slug>) the version grants: accepting is
    # what brings the copy. Only those two keys of $grant are read, so the
    # holder and the copy's target are $tenant whatever else it names. Throws
    # Registry::DAO::Entitlement::Refused, creating and copying nothing, as
    # Entitlement->accept does, or when the version is not one of registry's.
    #
    # A copy the tenant already holds is kept when it is the same as the
    # platform's (Registry::WorkflowDivergence). One that differs is replaced
    # only by a `replace` ruling for this tenant and slug in $rulings
    # (default: the recorded divergence report's); under a `merge` ruling or
    # none it is kept, and the result says why.
    #
    # All or nothing; joins the caller's transaction. Returns { entitlement,
    # workflows => { <slug> => copied | identical | replaced | kept: <why> } }.
    # Expects $db on the registry search path: on a tenant's, the accept finds no such version and refuses.
    sub accept_platform_offer ( $class, $db, $tenant, $grant, $rulings = undef ) {
        $db = $db->db if $db isa Registry::DAO;
        my $tx = $db->dbh->{AutoCommit} ? $db->begin : undef;
        my ( $version_id, $plan_id ) = @{$grant}{qw( offer_version_id payment_plan_id )};

        Registry::DAO::Entitlement::Refused->throw("Offer version @{[ $version_id // '' ]} is not the platform's offer.\n")
            unless $db->query( 'SELECT 1 FROM registry.offer_versions WHERE id::text = ?', $version_id // '' )->rows;
        my $entitlement = Registry::DAO::Entitlement->accept( $db,
            { offer_version_id => $version_id, payment_plan_id => $plan_id, holder_tenant_id => $tenant->id } );

        my %workflows;
        for my $wf ( $db->query( q{
            SELECT w.id, w.slug FROM registry.workflows w
             WHERE 'run:' || w.slug IN (
                   SELECT r.name FROM registry.offer_versions v
                     JOIN registry.resources r ON r.id = v.resource_id
                         OR r.id IN (SELECT s.resource_id FROM registry.offer_version_resources s
                                      WHERE s.offer_version_id = v.id)
                    WHERE v.id = ?)
             ORDER BY w.slug
        }, $version_id )->hashes->each ) {
            next if Registry::WorkflowDivergence::never_copied( $wf->{slug} );    # the platform's alone, granted or not
            my $schema = $db->dbh->quote_identifier( $tenant->slug );
            my $held   = $db->query( "SELECT id FROM $schema.workflows WHERE slug = ?", $wf->{slug} )->array;
            if ($held) {
                my @differs = Registry::WorkflowDivergence::differences_for( $db, $tenant->slug, $wf->{slug} );
                if ( !@differs ) { $workflows{ $wf->{slug} } = 'identical'; next }
                $rulings //= Registry::WorkflowDivergence::rulings();
                my $ruling = $rulings->{ $tenant->slug . "/$wf->{slug}" } // '';
                if ( $ruling ne 'replace' ) {
                    $workflows{ $wf->{slug} } = join "\n", ( $ruling eq 'merge'
                        ? 'kept: merge ruling, needs a hand merge' : 'kept: diverged, no ruling' ), @differs;
                    next;
                }
                $class->_drop_workflow_copy( $db, $schema, $held->[0] );
            }
            $class->_copy_platform_workflow( $db, $tenant->slug, $wf );
            $workflows{ $wf->{slug} } = $held ? 'replaced' : 'copied';
        }

        $tx->commit if $tx;
        return { entitlement => $entitlement, workflows => \%workflows };
    }

    # Deletes workflow $workflow_id from $schema (quoted): its steps, the
    # templates only they used, and its row.
    # shortcut: a copy with runs is refused by their foreign keys, rolling the
    # accept back; keep or move the runs once a replaced copy can have some.
    sub _drop_workflow_copy ( $class, $db, $schema, $workflow_id ) {
        my $templates = $db->query( "SELECT array_agg(DISTINCT template_id) FROM $schema.workflow_steps
                                      WHERE workflow_id = ?", $workflow_id )->array->[0] // [];
        $db->query( "DELETE FROM $schema.workflow_steps WHERE workflow_id = ?", $workflow_id );
        $db->query( "DELETE FROM $schema.templates t WHERE t.id = ANY(?::uuid[])
                        AND NOT EXISTS (SELECT 1 FROM $schema.workflow_steps s WHERE s.template_id = t.id)",
            [ grep { defined } @$templates ] );
        $db->query( "DELETE FROM $schema.workflows WHERE id = ?", $workflow_id );
    }

    # Copies registry's outcome definitions into tenant $slug's schema, those
    # workflow $workflow_id's steps use or, without one, all; any it already
    # holds is kept.
    sub _copy_outcome_definitions ( $class, $db, $slug, $workflow_id = undef ) {
        my $schema = $db->dbh->quote_identifier($slug);
        $db->query( qq{
            INSERT INTO ${schema}.outcome_definitions (id, name, description, schema)
            SELECT id, name, description, schema FROM registry.outcome_definitions
             WHERE ?::uuid IS NULL
                OR id IN (SELECT outcome_definition_id FROM registry.workflow_steps WHERE workflow_id = ?)
            ON CONFLICT DO NOTHING
        }, $workflow_id, $workflow_id );
    }

    # Copies registry workflow $wf ({ id, slug }) into tenant $slug's schema,
    # with its steps, templates, role data and the outcome definitions its
    # steps use.
    sub _copy_platform_workflow ( $class, $db, $slug, $wf ) {
        my $schema = $db->dbh->quote_identifier($slug);
        $class->_copy_outcome_definitions( $db, $slug, $wf->{id} );
        $db->query( 'SELECT copy_workflow(dest_schema => ?, workflow_id => ?)', $slug, $wf->{id} );
        return unless $wf->{slug} eq 'tenant-storefront';

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
    }

    # provision: single canonical path for creating a fully-provisioned tenant.
    # Creates the tenant row, clones the schema, copies seed data, copies all
    # workflows from registry (except those never_copied), copies users, and copies
    # OutcomeDefinitions.  The entire operation runs inside a single transaction
    # so a failure partway through does not leave orphaned rows or a half-cloned
    # schema.  Returns the created Tenant object.
    #
    # $data must contain: name (required), slug (optional), users (arrayref of
    # Registry::DAO::User objects or hashrefs with {id}).
    sub provision($class, $db, $data) {
        $db = $db->db if $db isa Registry::DAO;    # its transaction check needs the database handle
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
            name slug canonical_domain magic_link_expiry_hours
            stripe_connect_account_id stripe_charges_enabled stripe_details_submitted
            created_from_ip
        );
        my %tenant_data = map { $_ => $data->{$_} }
                          grep { exists $TENANT_COLUMNS{$_} } keys %$data;

        # Begin the transaction before any writes so that tenant row creation,
        # schema cloning, and all subsequent copies are atomic.  Postgres allows
        # CREATE SCHEMA (issued inside clone_schema) within a transaction.
        # Joins the caller's, so signup writes its users in the same one.
        my $tx = $db->dbh->{AutoCommit} ? $db->begin : undef;

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

        # Copy each supplied user into the tenant schema, and make them a
        # member: their role in the tenant is the membership's (ruling 4), so a
        # team member copied in without one would have none. The role is the
        # user_type chosen for them at signup; the primary's membership is
        # already there and is kept.
        for my $user (@$users) {
            my $user_id = ref $user eq 'HASH' ? $user->{id} : $user->id;
            $db->query('SELECT copy_user(dest_schema => ?, user_id => ?)',
                $tenant->slug, $user_id);
            $db->query( <<~'SQL', $tenant->id, $user_id );
                INSERT INTO registry.tenant_users (tenant_id, user_id, is_primary, role)
                SELECT ?, u.id, false, u.user_type FROM registry.users u WHERE u.id = ?
                ON CONFLICT (tenant_id, user_id) DO NOTHING
                SQL
        }

        # Outcome definitions before workflows: a copied step's
        # outcome_definition_id references the tenant's own table.
        $class->_copy_outcome_definitions( $db, $tenant->slug );

        # $data->{platform_entitlement} names { offer_version_id,
        # payment_plan_id }: the tenant accepts it in registry from now on,
        # which copies the workflows it grants, or the tenant is not created
        # (a refusal throws, rolling it all back).
        if ( my $grant = $data->{platform_entitlement} ) {
            $class->accept_platform_offer( $db, $tenant, $grant );
        }

        # Copy every other workflow in registry except tenant-signup; one the
        # accept above copied is not copied twice.
        my @workflows = $db->query( qq{
            SELECT id, slug FROM registry.workflows
             WHERE slug NOT IN (SELECT slug FROM ${schema}.workflows)
        } )->hashes->each;
        for my $wf (@workflows) {
            # tenant-signup onboards tenants; registry-storefront is the
            # platform's own shop window. Handing either to a tenant is the
            # mirror of the bug that made the apex serve a tenant's storefront.
            next if Registry::WorkflowDivergence::never_copied( $wf->{slug} );
            $class->_copy_platform_workflow( $db, $tenant->slug, $wf );
        }

        $tx->commit if $tx;

        return $tenant;
    }
}