# ABOUTME: offer-publishing step: the price, its currency, and what one acceptance buys.
# ABOUTME: Units per acceptance and a per-booking cap; whole smallest currency units only.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::OfferPrice :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Resource;

    # Nine digits at most, so every accepted value fits the integer columns.
    my $whole    = qr/\A[0-9]{1,9}\z/;
    my $positive = qr/\A[1-9][0-9]{0,8}\z/;

    # Why $units no longer fit the offer the run describes, or nothing; publish
    # asks again, since offer-basics can be answered again after this step. A
    # class offer is held to the smallest of its occurrences now; one added
    # later with less capacity is not refused here.
    sub refusal ( $class, $db, $data, $units ) {
        return 'Units per acceptance must be a whole number of at least one'
            unless defined $units && $units =~ /\A[1-9][0-9]{0,8}\z/;
        my $basic = ref $data->{offer_basics} eq 'HASH' ? $data->{offer_basics} : {};
        if ( my $class_id = $basic->{class_project_id} ) {
            my ( $name, $smallest ) = ( $db->query( q{
                SELECT p.name, min(r.capacity) FROM resources r
                  JOIN events e ON e.id = r.event_id JOIN projects p ON p.id = e.project_id
                 WHERE p.id = ? GROUP BY p.name
            }, $class_id )->array // [] )->@*;
            return sprintf 'Units per acceptance cannot exceed %d, the smallest capacity among %s\'s occurrences',
                $smallest, $name
                if defined $smallest && $units > $smallest;
            return;
        }
        my $resource = $basic->{resource_id} && Registry::DAO::Resource->find( $db, { id => $basic->{resource_id} } );
        return sprintf 'Units per acceptance cannot exceed %s\'s capacity of %d', $resource->name, $resource->capacity
            if $resource && $resource->kind eq 'finite' && $units > $resource->capacity;
        return;
    }

    method process ( $db, $form_data, $run = undef ) {
        my %f = map { $_ => ( ref $form_data->{$_} ? '' : $form_data->{$_} // '' ) }
            qw( price_cents currency units_per_acceptance per_booking_cap );

        my @errors;
        push @errors, 'The price must be a whole number of cents, zero or more'
            unless $f{price_cents} =~ $whole;
        push @errors, 'The currency must be a three-letter code such as USD'
            unless $f{currency} =~ /\A[A-Za-z]{3}\z/;
        push @errors, 'Units per acceptance must be a whole number of at least one'
            unless $f{units_per_acceptance} =~ $positive;
        push @errors, 'The per-booking cap must be a whole number of at least one'
            unless $f{per_booking_cap} =~ $positive;

        my $why = $f{units_per_acceptance} =~ $positive
            && __PACKAGE__->refusal( $db, $run ? $run->data : {}, $f{units_per_acceptance} );
        push @errors, $why if $why;

        return { stay => 1, errors => \@errors } if @errors;

        return { offer_price => {
            price_cents          => 0 + $f{price_cents},
            currency             => lc $f{currency},
            units_per_acceptance => 0 + $f{units_per_acceptance},
            per_booking_cap      => 0 + $f{per_booking_cap},
        } };
    }
}

1;
