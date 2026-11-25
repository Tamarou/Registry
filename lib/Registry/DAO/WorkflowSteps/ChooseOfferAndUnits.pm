# ABOUTME: in-studio-booking step: the visitor chooses one current offer covering the occurrence and how many of it.
# ABOUTME: Shows each offer's price, seats and policies in plain words; the system never picks an offer.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::ChooseOfferAndUnits :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Event;
    use Registry::DAO::Offer;
    use Registry::DAO::Resource;
    use Registry::Terms ();
    use Registry::DAO::WorkflowSteps::ChooseOccurrence;

    method process ( $db, $form_data, $run = undef ) {
        my ( $version, $count ) = $form_data->@{qw( offer_version_id count )};
        my $occurrence_id = $run && $run->data->{booking_occurrence_id};
        if ( my $refusal = __PACKAGE__->refusal( $db, $occurrence_id, $version, $count ) ) {
            return { stay => 1, errors => [$refusal] };
        }
        # The agreement is taken here, on the page that links /terms (ADR 005, ruling 12).
        if ( my $why = Registry::Terms::record_agreement( $db, $run, $form_data ) ) {
            return { stay => 1, errors => [$why] };
        }
        return { booking_offer_version_id => $version, booking_count => 0 + $count };
    }

    # The current offer versions covering occurrence-resource $occurrence_id.
    sub offers ( $class, $db, $occurrence_id ) {
        my $choose = 'Registry::DAO::WorkflowSteps::ChooseOccurrence';
        return [] unless $choose->bookable( $db, $occurrence_id );
        return [ grep { $_->buys( $db, $occurrence_id ) } $choose->current_versions($db)->@* ];
    }

    # Why $count of offer version $version_id may not be booked in occurrence
    # $occurrence_id now, or nothing. Asked again when the seats are held, so
    # a version superseded or an occurrence closed meanwhile is refused there.
    # Room is the hold's own check, under the occurrence's lock.
    sub refusal ( $class, $db, $occurrence_id, $version_id, $count ) {
        return 'Choose one of the listed classes'
            unless Registry::DAO::WorkflowSteps::ChooseOccurrence->bookable( $db, $occurrence_id );
        my $want = defined $version_id && !ref $version_id ? $version_id : '';
        my ($version) = grep { $_->id eq $want } $class->offers( $db, $occurrence_id )->@*;
        return 'Choose one of the listed offers' unless $version;
        return 'Choose how many, a whole number of at least one'
            unless defined $count && !ref $count && $count =~ /\A[1-9][0-9]*\z/;
        return sprintf 'This offer takes at most %d per booking', $version->per_booking_cap
            if $count > $version->per_booking_cap;
        return 'This offer cannot be booked online'
            unless grep { $_->{kind} eq 'one_time' } $version->payment_plans($db)->@*;
        return;
    }

    # $version's policies as the sentences a customer reads before choosing.
    sub policy_words ( $class, $version ) {
        my $p = $version->policies;
        my sub money ($cents) { $cents ? sprintf( 'for $%.2f', $cents / 100 ) : 'free of charge' }
        my %refund = (
            none              => sub { 'Sales are final.' },
            full_until_cutoff => sub ($r) {
                defined $r->{cutoff_hours}
                    ? "Full refund up to $r->{cutoff_hours} hours before."
                    : "Full refund until $r->{cutoff_at}.";
            },
            keep_fee_with_admin_exception => sub { 'Refunds keep the fee unless the studio makes an exception.' },
        );
        my %change = (
            none   => sub { 'Bookings cannot be rescheduled.' },
            window => sub ($c) { "Reschedule up to $c->{window_hours} hours before, " . money( $c->{fee_cents} ) . '.' },
        );
        my %use    = ( optional_attendance => sub { 'Attendance is recorded but not required.' } );
        my %expiry = ( end_of_occurrence   => sub { 'The booking ends when the class does.' } );
        my @words;
        for ( [ refund => \%refund ], [ change => \%change ], [ use => \%use ], [ expiry => \%expiry ] ) {
            my ( $name, $words ) = @$_;
            my $policy = $p->{$name} or next;
            my $say    = $words->{ $policy->{kind} } or next;
            push @words, $say->($policy);
        }
        return \@words;
    }

    method prepare_template_data ( $db, $run, $params = {} ) {
        my $occurrence_id = $run->data->{booking_occurrence_id};
        my @offers = map {
            {
                id     => $_->id,
                name   => Registry::DAO::Offer->find( $db, { id => $_->offer_id } )->name,
                price  => sprintf( '%.2f', $_->price_cents / 100 ),
                seats  => $_->units_per_acceptance,
                cap    => $_->per_booking_cap,
                policy => __PACKAGE__->policy_words($_),
            }
        } __PACKAGE__->offers( $db, $occurrence_id )->@*;
        my $resource = @offers && Registry::DAO::Resource->find( $db, { id => $occurrence_id } );
        return {
            offers     => \@offers,
            occurrence => $resource ? {
                class => $db->query( 'SELECT p.name FROM events e JOIN projects p ON p.id = e.project_id WHERE e.id = ?',
                    $resource->event_id )->array->[0],
                start => Registry::DAO::Event->find( $db, { id => $resource->event_id } )->local_start($db),
                free  => $resource->free_units($db),
            } : undef,
        };
    }
}

1;
