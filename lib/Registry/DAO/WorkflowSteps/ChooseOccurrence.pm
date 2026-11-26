# ABOUTME: in-studio-booking step: the visitor chooses one occurrence a current offer covers that is on sale with free seats.
# ABOUTME: Lists them in the location's local time; refuses any other id, including another tenant's or a past one.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::ChooseOccurrence :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Event;
    use Registry::DAO::OfferVersion;
    use Registry::DAO::Resource;

    my $UUID = qr/\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/i;

    method process ( $db, $form_data, $run = undef ) {
        # A run's start submits only what the link carried: show the list.
        return { stay => 1 } unless exists $form_data->{occurrence_id};
        my $id = $form_data->{occurrence_id};
        my $resource = __PACKAGE__->bookable( $db, $id )
            or return { stay => 1, errors => ['Choose one of the listed classes'] };
        return { stay => 1, errors => ['That class is full'] } unless $resource->free_units($db) > 0;
        return { booking_occurrence_id => $resource->id };
    }

    # This schema's published offer versions that are not superseded.
    sub current_versions ( $class, $db ) {
        return [ Registry::DAO::OfferVersion->find( $db,
            { published_at => { '!=' => undef }, superseded_at => undef }, { -asc => 'created_at' } ) ];
    }

    # The occurrence-resource $id when a booking may take seats in it now: in
    # this schema, covered by a current offer version, published and still to
    # start. Free seats are the caller's question.
    sub bookable ( $class, $db, $id ) {
        return undef unless defined $id && !ref $id && $id =~ $UUID;
        my $resource = Registry::DAO::Resource->find( $db, { id => $id } ) or return undef;
        return undef unless $resource->on_sale($db);
        return ( grep { $_->buys( $db, $id ) } $class->current_versions($db)->@* ) ? $resource : undef;
    }

    # Every occurrence on sale with a free seat, soonest first, in local time.
    method prepare_template_data ( $db, $run, $params = {} ) {
        my %seen;
        my @on_sale = grep { !$seen{ $_->id }++ && $_->event_id && $_->on_sale($db) }
            map { $_->covered_resources($db)->@* } __PACKAGE__->current_versions($db)->@*;
        my @occurrences;
        for my $resource (@on_sale) {
            my $free = $resource->free_units($db) or next;
            my $event = Registry::DAO::Event->find( $db, { id => $resource->event_id } );
            push @occurrences, {
                id    => $resource->id,
                class => $db->select( 'projects', 'name', { id => $event->project_id } )->array->[0],
                start => $event->local_start($db),
                free  => $free,
                at    => $event->time,
            };
        }
        return { occurrences => [ sort { $a->{at} cmp $b->{at} } @occurrences ] };
    }
}

1;
