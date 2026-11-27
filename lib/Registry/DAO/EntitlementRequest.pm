# ABOUTME: A refund or change whose policy needs an admin's approval: the outcome the policy computed, for one run.
# ABOUTME: An admin approves or declines it once; a second decision, racing or late, changes nothing.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::EntitlementRequest :isa(Registry::DAO::Object) {
    use Carp qw( croak );
    use Registry::DAO::Entitlement;

    field $id :param :reader;
    field $entitlement_id :param :reader;
    field $kind :param :reader;    # refund or change
    field $workflow_run_id :param :reader;
    field $outcome :param :reader;
    field $state :param :reader;    # pending, approved or declined
    field $requested_by :param :reader;
    field $decided_by :param :reader = undef;
    field $decided_at :param :reader = undef;
    field $note :param :reader = undef;
    field $created_at :param :reader;

    sub table { 'entitlement_requests' }

    # Refused while the entitlement already has a pending request, of either
    # kind: two pending requests could both be approved and refund it twice.
    sub open ( $class, $db, $data ) {
        $db = $db->db if $db isa Registry::DAO;
        my $row = $db->query( q{
            INSERT INTO entitlement_requests (entitlement_id, kind, workflow_run_id, outcome, requested_by)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (entitlement_id) WHERE state = 'pending' DO NOTHING
            RETURNING *
        }, @$data{qw( entitlement_id kind workflow_run_id )}, { json => $data->{outcome} }, $data->{requested_by} )
            ->expand->hash;
        Registry::DAO::Entitlement::Refused->throw(
            "Entitlement $data->{entitlement_id} already has a pending request awaiting an admin's decision.\n")
            unless $row;
        return $class->new(%$row);
    }

    sub for_run ( $class, $db, $run_id ) {
        return scalar $class->find( $db, { workflow_run_id => $run_id } );
    }

    # Pending requests, oldest first, each with its child's and offer's names.
    sub pending ( $class, $db ) {
        $db = $db->db if $db isa Registry::DAO;
        return $db->query( q{
            SELECT r.*, fm.child_name, o.name AS offer_name
              FROM entitlement_requests r
              JOIN entitlements e ON e.id = r.entitlement_id
              JOIN offers o ON o.id = e.offer_id
              LEFT JOIN family_members fm ON fm.id = e.holder_family_member_id
             WHERE r.state = 'pending'
             ORDER BY r.created_at, r.id
        } )->expand->hashes->to_array;
    }

    # True when this decision is the one taken; false when the request was
    # already decided, so two admins deciding at once get one true between them.
    method decide ( $db, $to, $admin_id, $why = undef ) {
        croak "unknown decision state '$to': a request is approved or declined" unless $to =~ /\A(?:approved|declined)\z/;
        $db = $db->db if $db isa Registry::DAO;
        my $row = $db->update( 'entitlement_requests',
            { state => $to, decided_by => $admin_id, decided_at => \'clock_timestamp()', note => $why },
            { id => $id, state => 'pending' }, { returning => [qw( state decided_by decided_at note )] } )->hash;
        return false unless $row;
        ( $state, $decided_by, $decided_at, $note ) = @$row{qw( state decided_by decided_at note )};
        return true;
    }
}

1;
