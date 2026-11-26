# ABOUTME: One numbered version of a PriceOps offer: editable as a draft, immutable once published.
# ABOUTME: The database enforces immutability; this class only appends and publishes.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::OfferVersion :isa(Registry::DAO::Object) {
    use Carp qw( croak );
    use Scalar::Util qw( blessed );
    use Mojo::JSON qw( to_json );
    use Registry::DAO::Resource;

    field $id :param :reader;
    field $offer_id :param :reader;
    field $version :param :reader;
    field $resource_id :param :reader = undef;         # the one resource it buys, or
    field $class_project_id :param :reader = undef;    # the class whose occurrences it covers, or
                                                       # neither: the set in offer_version_resources
    field $price_cents :param :reader;             # whole smallest currency units
    field $currency :param :reader;                # lowercase ISO 4217, as Stripe takes it
    field $units_per_acceptance :param :reader;    # e.g. 2 seats for a couple
    field $per_booking_cap :param :reader;         # acceptances one booking may take
    field $policies :param :reader = {};           # { refund, change, use, expiry }
    field $conditions :param :reader = [];         # checked at acceptance (later)
    field $published_at :param :reader = undef;
    field $superseded_at :param :reader = undef;
    field $created_at :param :reader;

    sub table { 'offer_versions' }

    method is_published { defined $published_at }

    # The resources accepting this version buys units of: its one resource,
    # each resource of its set, or every occurrence-resource of its class,
    # including ones made after it was published, in occurrence order. The one
    # coverage rule.
    method covered_resources ($db) {
        $db = $db->db if $db isa Registry::DAO;
        return $db->query( q{
            SELECT r.* FROM resources r LEFT JOIN events e ON e.id = r.event_id
             WHERE r.id = ? OR e.project_id = ?
                OR r.id IN (SELECT resource_id FROM offer_version_resources WHERE offer_version_id = ?)
             ORDER BY e.time, r.id
        }, $resource_id, $class_project_id, $id )->hashes
            ->map( sub { Registry::DAO::Resource->new(%$_) } )->to_array;
    }

    # Whether accepting this version buys units of $resource_id.
    method buys ( $db, $resource_id ) {
        return !!grep { $_->id eq $resource_id } $self->covered_resources($db)->@*;
    }

    # The seats a booking of $count acceptances takes: $count times its seats
    # per unit, refused unless a whole number from 1 to the per-booking cap.
    # Capacity is then the resource's one check (Resource->claim).
    method seats_for ($count) {
        # Checked as a count, not as seats: 1.5 couples is 3 whole seats.
        croak 'a booking is a whole number of at least one: ' . ( $count // 'nothing' ) . ' asked for'
            unless defined $count && $count =~ /\A[1-9][0-9]*\z/;
        croak "a booking of this offer takes at most $per_booking_cap: $count asked for"
            if $count > $per_booking_cap;
        return $count * $units_per_acceptance;
    }

    # Platform terms rows (Registry::PriceOps::PlatformTerms): what every
    # lookup returns about a registry offer version and one of its plans.
    my $TERMS_COLUMNS = q{
        v.id, p.id AS plan_id, o.name, v.price_cents, p.fraction,
        v.policies->'refund' AS refund_policy
    };

    # The terms row of the entitlement tenant $slug holds to $resource in
    # effect at $at (default now), or undef. At most one row: the database
    # refuses overlapping active platform entitlements to payment processing
    # (platform-entitlement-one-in-effect).
    sub platform_terms_row_for_tenant ( $class, $db, $slug, $resource, $at = undef ) {
        require Registry::DAO::Entitlement;
        my $in_effect = Registry::DAO::Entitlement->in_effect_sql( 'e',
            q{tstzrange(coalesce(?::timestamptz, now()), coalesce(?::timestamptz, now()), '[]')} );
        return $db->query( qq{
            SELECT $TERMS_COLUMNS
              FROM registry.entitlements e
              JOIN registry.tenants t ON t.id = e.holder_tenant_id
              JOIN registry.offer_versions v ON v.id = e.offer_version_id
              JOIN registry.offers o ON o.id = v.offer_id
              JOIN registry.resources r ON r.id = v.resource_id
                  OR r.id IN (SELECT s.resource_id FROM registry.offer_version_resources s
                              WHERE s.offer_version_id = v.id)
              JOIN registry.offer_version_payment_plans p
                ON p.offer_version_id = v.id AND p.id = e.payment_plan_id
             WHERE t.slug = ? AND r.name = ? AND $in_effect
        }, $slug, $resource, $at, $at )->hash;
    }

    # The terms row of registry offer version $version_id with plan $plan_id,
    # superseded or not, when it buys $resource; else undef.
    sub platform_terms_row ( $class, $db, $version_id, $plan_id, $resource ) {
        return $db->query( qq{
            SELECT $TERMS_COLUMNS
              FROM registry.offer_versions v
              JOIN registry.offers o ON o.id = v.offer_id
              JOIN registry.resources r ON r.id = v.resource_id
                  OR r.id IN (SELECT s.resource_id FROM registry.offer_version_resources s
                              WHERE s.offer_version_id = v.id)
              JOIN registry.offer_version_payment_plans p ON p.offer_version_id = v.id
             WHERE v.id = ? AND p.id = ? AND r.name = ?
        }, $version_id, $plan_id, $resource )->hash;
    }

    # Terms rows, with currency and offer_id, of registry's current published
    # free versions buying $resource with a percentage-of-sales plan, less its
    # offers to itself (holder_is_offerer), cheapest first.
    sub platform_offer_rows ( $class, $db, $resource ) {
        return $db->query( qq{
            SELECT $TERMS_COLUMNS, v.currency, v.offer_id
              FROM registry.offer_versions v
              JOIN registry.offers o ON o.id = v.offer_id
              JOIN registry.resources r ON r.id = v.resource_id
                  OR r.id IN (SELECT s.resource_id FROM registry.offer_version_resources s
                              WHERE s.offer_version_id = v.id)
              JOIN registry.offer_version_payment_plans p
                ON p.offer_version_id = v.id AND p.kind = 'percentage_of_sales'
             WHERE r.name = ?
               AND v.published_at IS NOT NULL AND v.superseded_at IS NULL
               AND v.price_cents = 0
               AND NOT v.conditions \@> '[{"kind": "holder_is_offerer"}]'
             ORDER BY p.fraction, o.name
        }, $resource )->hashes;
    }

    # Drafting and publishing both read the offer's versions and then write
    # one, so two writers to the same offer take turns on the offer row. Without
    # it the second computes the same next number, or retires a version the
    # first is replacing, and the database refuses it instead of queueing it.
    # Joins the caller's transaction when there is one, so a workflow step can
    # publish inside its own.
    sub _with_offer_locked ( $db, $offer_id, $code ) {
        my $tx = $db->dbh->{AutoCommit} ? $db->begin : undef;
        $db->query( 'SELECT 1 FROM offers WHERE id = ? FOR UPDATE', $offer_id );
        my $result = $code->();
        $tx->commit if $tx;
        return $result;
    }

    # The declared policy shapes: policy => kind => the field sets that kind
    # may carry, each field with its check. A policy must match one field set
    # exactly; anything else is refused, never guessed at. A new kind arrives
    # as a new entry here and the workflow step that applies it.
    my $whole   = sub ($v) { defined $v && !ref $v && $v =~ /\A[0-9]+\z/ };
    my $instant = sub ($v) {
        defined $v && !ref $v
            && $v =~ /\A\d{4}-\d\d-\d\dT\d\d:\d\d(?::\d\d)?(?:Z|[+-]\d\d:\d\d)\z/;
    };
    my %POLICY = (
        refund => {
            none                          => [ {} ],
            full_until_cutoff             => [ { cutoff_hours => $whole }, { cutoff_at => $instant } ],
            keep_fee_with_admin_exception => [ {} ],
        },
        change => {
            none   => [ {} ],
            window => [ {
                window_hours => $whole,
                fee_cents    => $whole,
                # shortcut: only the same offer's occurrences, the day-one rule;
                # other targets are a new value here when a product needs them.
                targets => sub ($v) { ( $v // '' ) eq 'same_offer' },
            } ],
        },
        use    => { optional_attendance => [ {} ], none  => [ {} ] },
        expiry => { end_of_occurrence   => [ {} ], never => [ {} ] },
    );

    # True when $data, less its kind, has exactly $shape's fields, each passing.
    my $fits = sub ( $data, $shape ) {
        my %fields = %$data;
        delete $fields{kind};
        keys %fields == keys %$shape
            && !grep { !$shape->{$_} || !$shape->{$_}->( $fields{$_} ) } keys %fields;
    };

    # Conditions are declared the same way: kind => its fields' checks.
    my $uuid = sub ($v) {
        defined $v && !ref $v && $v =~ /\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/i;
    };
    my %CONDITION = (
        # The sibling rate: the holder's family holds an entitlement to offer_id.
        family_holds_entitlement => { offer_id => $uuid },
        # The platform's offer to itself: only the offerer may hold it, so it
        # is not offered to tenants.
        holder_is_offerer => {},
    );

    sub _check_conditions ($conditions) {
        croak 'conditions must be a list' unless ref $conditions eq 'ARRAY';
        for my $condition (@$conditions) {
            croak 'a condition must be an object' unless ref $condition eq 'HASH';
            my $kind  = $condition->{kind} // '';
            my $shape = $CONDITION{$kind} or croak "unknown condition kind '$kind'";
            $fits->( $condition, $shape ) or croak "malformed condition '$kind'";
        }
    }

    sub _check_policies ($policies) {
        croak 'policies must be an object' unless ref $policies eq 'HASH';
        for my $name ( sort keys %$policies ) {
            my $kinds  = $POLICY{$name} or croak "unknown policy '$name'";
            my $policy = $policies->{$name};
            croak "$name policy must be an object" unless ref $policy eq 'HASH';
            my $kind   = $policy->{kind} // '';
            my $shapes = $kinds->{$kind} or croak "unknown $name policy kind '$kind'";
            grep( { $fits->( $policy, $_ ) } @$shapes ) or croak "malformed $name policy '$kind'";
        }
    }

    # Appends the offer's next version number as a draft. $terms names one
    # resource_id, one class_project_id, or resource_ids: the set it buys.
    sub draft ( $class, $db, $offer_id, $terms ) {
        $db = $db->db if $db isa Registry::DAO;
        my $policies = $terms->{policies} // {};
        _check_policies($policies);
        my $conditions = $terms->{conditions} // [];
        _check_conditions($conditions);
        my $row = _with_offer_locked( $db, $offer_id, sub {
            my $row = $db->query(
                'INSERT INTO offer_versions (offer_id, version, resource_id, class_project_id,
                        price_cents, currency, units_per_acceptance, per_booking_cap, policies, conditions)
                 SELECT ?, coalesce(max(version), 0) + 1, ?, ?, ?, ?, ?, ?, ?::jsonb, ?::jsonb
                   FROM offer_versions WHERE offer_id = ?
                 RETURNING *',
                $offer_id, $terms->@{qw( resource_id class_project_id price_cents )},
                $terms->{currency} // 'usd',
                $terms->@{qw( units_per_acceptance per_booking_cap )},
                to_json($policies), to_json($conditions), $offer_id )->expand->hash;
            $db->insert( 'offer_version_payment_plans',
                { offer_version_id => $row->{id}, $_->%{qw( id kind fraction )} } )
                for ( $terms->{payment_plans} // [] )->@*;
            $db->insert( 'offer_version_resources', { offer_version_id => $row->{id}, resource_id => $_ } )
                for ( $terms->{resource_ids} // [] )->@*;
            $row;
        } );
        return $class->new(%$row);
    }

    # The plans a customer chooses between, each { id, kind, fraction }.
    method payment_plans ($db) {
        $db = $db->db if $db isa Registry::DAO;
        return $db->select( 'offer_version_payment_plans', [qw( id kind fraction )],
            { offer_version_id => $id }, { -asc => 'id' } )->hashes->to_array;
    }

    # Publishes this draft and supersedes the offer's current version, in one
    # transaction: an offer with two current versions is refused by the
    # database, and one with none would sell nothing.
    method publish ($db) {
        $db = $db->db if $db isa Registry::DAO;
        my $row = _with_offer_locked( $db, $offer_id, sub {
            # Absence is not zero: an offer must say how it is paid for and what
            # a refund is. The database refuses both too, the plan at commit by
            # offer_versions_require_payment_plan; these say so before writing.
            croak "offer $offer_id version $version has no payment plan"
                unless @{ $self->payment_plans($db) };
            croak "offer $offer_id version $version has no refund policy"
                unless exists $policies->{refund};

            # Retired first, or the one-current index refuses the publish. Only
            # an older version is retired, so publishing a stale draft over a
            # newer current version is refused by that index.
            $db->query(
                'UPDATE offer_versions SET superseded_at = now()
                  WHERE offer_id = ? AND version < ?
                    AND published_at IS NOT NULL AND superseded_at IS NULL',
                $offer_id, $version );

            $db->query(
                'UPDATE offer_versions SET published_at = now()
                  WHERE id = ? AND published_at IS NULL RETURNING *', $id )->expand->hash
                or croak "offer $offer_id version $version is already published";
        } );
        return blessed($self)->new(%$row);
    }
}

1;
