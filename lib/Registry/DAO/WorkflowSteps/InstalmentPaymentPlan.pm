# ABOUTME: session-setup step: whether a session may be paid in instalments, and their count, cadence and surcharge.
# ABOUTME: A plan whose last payment, bought today, falls after a covered session's last day is refused, never clamped.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::InstalmentPaymentPlan :isa(Registry::DAO::WorkflowStep) {
    use Registry::PriceOps::Instalments qw( fits );

    my %CADENCE = map { $_ => 1 } qw( weekly monthly quarterly );

    # Why $plan cannot be offered on the run's resources, or nothing. Each
    # session's last day and today are read in its location's zone; the
    # earliest-ending session is the one a plan must fit. Publish asks again,
    # since the offer's resources can be chosen after this step.
    sub refusal ( $class, $db, $data, $plan ) {
        my $basic = ref $data->{offer_basics} eq 'HASH' ? $data->{offer_basics} : {};
        my @ids   = grep { defined && !ref } $basic->{resource_id},
            ref $basic->{resource_ids} eq 'ARRAY' ? $basic->{resource_ids}->@* : ();
        return unless @ids;
        my $session = $db->query( q{
            SELECT r.name, to_char(max(e.time AT TIME ZONE l.time_zone), 'YYYY-MM-DD') AS last_day,
                   to_char(now() AT TIME ZONE l.time_zone, 'YYYY-MM-DD') AS today
              FROM resources r JOIN events e ON e.id = r.event_id OR e.session_resource_id = r.id
              JOIN locations l ON l.id = e.location_id
             WHERE r.id::text = ANY(?) GROUP BY r.id, r.name, l.time_zone ORDER BY last_day LIMIT 1
        }, \@ids )->hash or return;
        return if fits( $plan, $session->{today}, $session->{last_day} );
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
