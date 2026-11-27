# ABOUTME: session-setup step: whether a session may be paid in instalments, and their count, cadence and surcharge.
# ABOUTME: A plan whose last payment, bought today, falls after a covered session's last day is refused, never clamped.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::InstalmentPaymentPlan :isa(Registry::DAO::WorkflowStep) {
    use Registry::PriceOps::Instalments qw( fits parts );

    my %CADENCE = map { $_ => 1 } qw( weekly monthly quarterly );

    # Why $plan cannot be offered on the offer's resources, or nothing.
    # Publish asks again, since the offer's resources can be chosen after this step.
    sub refusal ( $class, $db, $data, $plan ) {
        # Every part is a charge, so none may be zero: the price with its
        # surcharge must be at least a cent per part.
        my $cents = ( ref $data->{offer_price} eq 'HASH' ? $data->{offer_price} : {} )->{price_cents};
        return sprintf 'A price of %d cent%s cannot be split into %d payments of at least a cent each',
            $cents, $cents == 1 ? '' : 's', $plan->{count}
            if defined $cents && !ref $cents && $cents =~ /\A[0-9]+\z/
            && !parts( $cents, $plan, '2000-01-01' )->[0]{amount_cents};    # the first part is the smallest
        my $basic = ref $data->{offer_basics} eq 'HASH' ? $data->{offer_basics} : {};
        my @ids   = grep { defined && !ref } $basic->{resource_id},
            ref $basic->{resource_ids} eq 'ARRAY' ? $basic->{resource_ids}->@* : ();
        # Before an offer names its sessions, every session the run made.
        @ids = grep { defined && !ref } $data->{sessions}->@* if !@ids && ref $data->{sessions} eq 'ARRAY';
        return unless @ids;
        # Grouped by session alone, so a session whose days span two
        # locations is judged on all of them, each day read in its own zone;
        # today is the latest local today among its locations.
        my $sessions = $db->query( q{
            SELECT r.name, max(to_char(e.time AT TIME ZONE l.time_zone, 'YYYY-MM-DD')) AS last_day,
                   max(to_char(now() AT TIME ZONE l.time_zone, 'YYYY-MM-DD')) AS today
              FROM resources r JOIN events e ON e.id = r.event_id OR e.session_resource_id = r.id
              JOIN locations l ON l.id = e.location_id
             WHERE r.id::text = ANY(?) GROUP BY r.id, r.name ORDER BY last_day, r.name
        }, \@ids )->hashes;
        # The earliest-ending session that the plan does not fit.
        my ($session) = grep { !fits( $plan, $_->{today}, $_->{last_day} ) } @$sessions or return;
        return sprintf 'A %s plan of %d payments bought today would end after %s, the last day of %s',
            $plan->{cadence}, $plan->{count}, $session->@{qw( last_day name )};
    }

    method process ( $db, $form_data, $run = undef ) {
        my %f = map { $_ => ( ref $form_data->{$_} ? '' : $form_data->{$_} // '' ) }
            qw( instalments count cadence surcharge_pct );
        return { stay => 1, errors => ['Say whether instalments are offered'] }
            unless $f{instalments} eq 'offered' || $f{instalments} eq 'declined';
        return { instalment_payment => undef } if $f{instalments} eq 'declined';

        # The offer_version_payment_plans checks' ranges, asked here first.
        my @errors;
        push @errors, 'The number of payments is a whole number from 2 to 52'
            unless $f{count} =~ /\A[0-9]{1,2}\z/ && $f{count} >= 2 && $f{count} <= 52;
        push @errors, 'Choose weekly, monthly or quarterly payments' unless $CADENCE{ $f{cadence} };
        push @errors, 'The surcharge is a percent from 0 to 100 with at most 2 decimal places, such as 2.5'
            unless $f{surcharge_pct} eq ''
            || ( $f{surcharge_pct} =~ /\A[0-9]{1,3}(?:\.[0-9]{1,2})?\z/ && $f{surcharge_pct} <= 100 );
        return { stay => 1, errors => \@errors } if @errors;

        my $plan = { id => 'parts', count => 0 + $f{count}, cadence => $f{cadence},
            surcharge_pct => length $f{surcharge_pct} ? $f{surcharge_pct} : undef };
        my $why = __PACKAGE__->refusal( $db, $run ? $run->data : {}, $plan );
        return { stay => 1, errors => [$why] } if $why;
        return { instalment_payment => $plan };
    }
}

1;
