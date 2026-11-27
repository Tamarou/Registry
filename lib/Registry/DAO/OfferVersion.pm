# ABOUTME: One numbered version of a PriceOps offer: editable as a draft, immutable once published.
# ABOUTME: The database enforces immutability; this class only appends and publishes.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::OfferVersion :isa(Registry::DAO::Object) {
    use Carp qw( croak );
    use Scalar::Util qw( blessed );
    use Mojo::JSON qw( to_json );
    use DateTime;
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
        }, $resource_id, $class_project_id, $id )->expand->hashes
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
    # exactly; anything else is refused, never guessed at. An optional field's
    # check accepts its absence. A new kind arrives as a new entry here and the
    # workflow step that applies it.
    my $whole    = sub ($v) { defined $v && !ref $v && $v =~ /\A[0-9]+\z/ };
    # Day and hour counts stop at ten years' worth, so no later cast overflows.
    my $capped   = sub ($v) { $whole->($v) && length $v <= 4 && $v <= 3650 };
    my $hours    = sub ($v) { $whole->($v) && length $v <= 5 && $v <= 87600 };
    my $positive = sub ($v) { $capped->($v) && $v > 0 };
    # An ISO 8601 instant with its offset that names a real date and time, as
    # Postgres will read it: DateTime refuses 2027-02-30 and 25:00, and Postgres
    # refuses offsets beyond 15:59.
    my $instant = sub ($v) {
        return !!0 unless defined $v && !ref $v && $v =~ /\A
            ([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2})(?::([0-9]{2}))?
            (?:Z|[+-]([0-9]{2}):([0-9]{2}))\z/x;
        my ( $y, $mo, $d, $h, $mi, $sec, $oh, $om ) = ( $1, $2, $3, $4, $5, $6 // 0, $7 // 0, $8 // 0 );
        return !!0 if $oh > 15 || $om > 59;
        return !!eval {
            DateTime->new( year => $y, month => $mo, day => $d, hour => $h, minute => $mi, second => $sec );
        };
    };
    my $uuid = sub ($v) {
        defined $v && !ref $v && $v =~ /\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/i;
    };
    my $offer_ids = sub ($v) { ref $v eq 'ARRAY' && @$v && !grep { !$uuid->($_) } @$v };
    my $one_of    = sub (@ok) { sub ($v) { defined $v && !ref $v && grep { $_ eq $v } @ok } };
    my $optional  = sub ($check) { sub ($v) { !defined $v || $check->($v) } };
    my $approval  = $optional->( $one_of->(qw( required none )) );
    my %POLICY = (
        refund => {
            none                          => [ { approval => $approval } ],
            full_until_cutoff             => [ { cutoff_hours => $hours,   approval => $approval },
                                               { cutoff_at    => $instant, approval => $approval } ],
            keep_fee_with_admin_exception => [ { approval => $approval } ],
        },
        change => {
            none   => [ {} ],
            window => [ {
                window_hours => $hours,
                fee_cents    => $whole,
                targets      => sub ($v) {
                    ref $v eq 'HASH'
                        ? keys %$v == 1 && $offer_ids->( $v->{offer_ids} )
                        : $one_of->(qw( same_offer same_program ))->($v);
                },
                price_difference => $optional->( $one_of->(qw( charge_and_refund charge_only same_price_only )) ),
                approval         => $approval,
            } ],
        },
        use => {
            optional_attendance => [ {} ],
            none                => [ {} ],
            makeup => [ { offer_id => $uuid, credit_days => $positive, max_per_term => $optional->($positive) } ],
        },
        missed_payment => { keep_and_owe => [ {} ], end => [ {} ], grace => [ { days => $positive } ] },
        expiry         => { end_of_occurrence => [ {} ], never => [ {} ] },
    );

    # True when every field of $data, less its kind, is one of $shape's and
    # present (never null), and each of $shape's checks passes.
    my $fits = sub ( $data, $shape ) {
        my %fields = %$data;
        delete $fields{kind};
        !grep( { !$shape->{$_} || !defined $fields{$_} } keys %fields )
            && !grep { !$shape->{$_}->( $fields{$_} ) } keys %$shape;
    };

    # Conditions are declared the same way: kind => its fields' checks.
    my %CONDITION = (
        # The sibling rate: the holder's family holds an entitlement to one of
        # offer_ids, or to any offer when it is absent.
        family_holds_entitlement => { offer_ids => $optional->($offer_ids) },
        # The early-bird rate: chosen only until at.
        before => { at => $instant },
        # The platform's offer to itself: only the offerer may hold it, so it
        # is not offered to tenants.
        holder_is_offerer => {},
    );

    # What a refund or change policy says about approval: absent is none,
    # since a published version cannot gain the field.
    sub approval_for ( $class, $policy ) { $policy->{approval} // 'none' }

    # How a change policy treats a price difference: absent is same_price_only.
    sub price_difference_for ( $class, $change ) { $change->{price_difference} // 'same_price_only' }

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

    # A payment plan's fields; the database checks each against its kind.
    my @PLAN_FIELDS = qw( id kind fraction count cadence surcharge_pct );

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
                { offer_version_id => $row->{id}, $_->%{@PLAN_FIELDS} } )
                for ( $terms->{payment_plans} // [] )->@*;
            $db->insert( 'offer_version_resources', { offer_version_id => $row->{id}, resource_id => $_ } )
                for ( $terms->{resource_ids} // [] )->@*;
            $row;
        } );
        return $class->new(%$row);
    }

    # Whether a condition is met for $ctx at instant $at, by kind; and the
    # sentence saying it is not. Instants are compared in Postgres, never as
    # local dates.
    my %MET = (
        family_holds_entitlement => sub ( $db, $condition, $ctx, $at ) {
            my $offer_ids = $condition->{offer_ids};
            my %counts    = map { $_ => 1 } ( $offer_ids // [] )->@*;
            my $holder    = $ctx->{holder_family_member_id};
            # A child's own earlier line is not a sibling's.
            return 1 if grep { ( $_->{family_member_id} // '' ) ne ( $holder // '' )
                    && ( !$offer_ids || $counts{ $_->{offer_id} // '' } ) } ( $ctx->{cart_lines} // [] )->@*;
            require Registry::DAO::Entitlement;
            # Active and not yet over at $at: a sibling bought for a session
            # that has not started yet counts.
            my $in_effect = Registry::DAO::Entitlement->in_effect_sql( 'e', q{tstzrange(?::timestamptz, NULL)} );
            return $db->query( qq{
                SELECT EXISTS (SELECT 1 FROM family_members holder
                    JOIN family_members sibling
                      ON sibling.family_id = holder.family_id AND sibling.id <> holder.id
                    JOIN entitlements e ON e.holder_family_member_id = sibling.id
                   WHERE holder.id = ? AND $in_effect
                     AND (?::uuid[] IS NULL OR e.offer_id = ANY (?::uuid[])))
            }, $holder, $at, $offer_ids, $offer_ids )->array->[0];
        },
        before => sub ( $db, $condition, $ctx, $at ) {
            $db->query( 'SELECT ?::timestamptz < ?::timestamptz', $at, $condition->{at} )->array->[0];
        },
        # Only the platform's offer to itself carries it; no checkout meets it.
        holder_is_offerer => sub { 0 },
    );
    my %UNMET = (
        family_holds_entitlement => sub ($c) { 'This price is for a child whose brother or sister already holds a place here.' },
        before                   => sub ($c) { "This price could be chosen only until $c->{at}." },
        holder_is_offerer        => sub ($c) { 'This offer is held only by the one who offers it.' },
    );

    # $ctx->{at}, refused unless an instant with its offset: a local time
    # names no one moment.
    my $at_of = sub ($ctx) {
        my $at = $ctx->{at};
        croak 'conditions are met or not at an instant with its offset, not ' . ( $at // 'nothing' )
            unless $instant->($at);
        return $at;
    };

    # A sentence for each of its conditions the child in $ctx does not meet at
    # $ctx->{at}; none when it may choose this version. $ctx names
    # holder_family_member_id, at (an instant with its offset) and cart_lines:
    # the earlier lines of the cart, each { family_member_id, offer_id }.
    method unmet_conditions ( $db, $ctx ) {
        $db = $db->db if $db isa Registry::DAO;
        my $at = $at_of->($ctx);
        return [ map { $UNMET{ $_->{kind} }->($_) } grep {
            my $met = $MET{ $_->{kind} // '' }
                or croak "unknown condition kind '" . ( $_->{kind} // '' ) . "': it cannot be evaluated";
            !$met->( $db, $_, $ctx, $at );
        } @$conditions ];
    }

    # Every current version buying $resource_id, each { version, unmet }, by
    # price, offer name, then id: the child in $ctx may choose those with no
    # unmet conditions, and the first of them is preselected.
    sub choosable_for ( $class, $db, $resource_id, $ctx ) {
        $db = $db->db if $db isa Registry::DAO;
        $at_of->($ctx);
        # Narrowed here; buys stays the one coverage rule and the final word.
        return [ map { { version => $_, unmet => $_->unmet_conditions( $db, $ctx ) } }
                grep { $_->buys( $db, $resource_id ) }
                $db->query( q{
                    SELECT v.* FROM offer_versions v JOIN offers o ON o.id = v.offer_id
                     WHERE v.published_at IS NOT NULL AND v.superseded_at IS NULL
                       AND ( v.resource_id = ?
                          OR v.id IN (SELECT offer_version_id FROM offer_version_resources WHERE resource_id = ?)
                          OR v.class_project_id IN (SELECT e.project_id FROM resources r
                                                      JOIN events e ON e.id = r.event_id
                                                     WHERE r.id = ?) )
                     ORDER BY v.price_cents, o.name, v.id
                }, ($resource_id) x 3 )->expand->hashes->map( sub { $class->new(%$_) } )->each ];
    }

    # The plans a customer chooses between, each { id, kind, fraction, count,
    # cadence, surcharge_pct }; a field its kind does not carry is undef.
    method payment_plans ($db) {
        $db = $db->db if $db isa Registry::DAO;
        return $db->select( 'offer_version_payment_plans', [@PLAN_FIELDS],
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
            # What a missed instalment does is never left unspecified; the
            # database refuses it too (offer_versions_instalments_need_missed_payment).
            croak "offer $offer_id version $version offers instalments and has no missed_payment policy"
                if !exists $policies->{missed_payment}
                && grep { $_->{kind} eq 'instalments' } @{ $self->payment_plans($db) };
            # A draft stored by raw SQL or before a shape was retired never
            # passed draft's checks; nothing is published unchecked.
            _check_policies($policies);
            _check_conditions($conditions);

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
