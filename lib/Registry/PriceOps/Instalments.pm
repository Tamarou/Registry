# ABOUTME: Instalment cadence arithmetic for an offer version's instalments plan: due dates, parts, and the fit to a last day.
# ABOUTME: Pure functions on YYYY-MM-DD strings and whole cents, shared by session-setup, checkout, holds and schedules.
package Registry::PriceOps::Instalments;
use 5.42.0;
use utf8;

use Exporter 'import';
use DateTime;

our @EXPORT_OK = qw( due_dates parts fits );

my %MONTHS = ( monthly => 1, quarterly => 3 );

# $plan's count due dates from $first_date: weekly every seven days; monthly
# and quarterly a whole number of months from the first, clamped to the end
# of the month, as Stripe bills a schedule (2027-01-31, 02-28, 03-31, 04-30).
sub due_dates ( $plan, $first_date ) {
    my ( $count, $cadence ) = $plan->@{qw( count cadence )};
    die "unknown cadence '$cadence'\n" unless $cadence eq 'weekly' || $MONTHS{$cadence};
    return [ map {
        $cadence eq 'weekly' ? _plus_days( $first_date, 7 * $_ ) : _plus_months( $first_date, $MONTHS{$cadence} * $_ )
    } 0 .. $count - 1 ];
}

# $total_cents as [ { amount_cents, due_date } ]: the surcharge first, then an
# even split with the remainder on the last part, as
# PricingPlan::instalment_schedule. The surcharge, a percent with at most two
# places, is applied in whole basis points and rounded half up: no float.
sub parts ( $total_cents, $plan, $first_date ) {
    my ( $whole, $places ) = ( $plan->{surcharge_pct} // 0 ) =~ /\A([0-9]+)(?:\.([0-9]{1,2}))?\z/a
        or die "not a surcharge percent: $plan->{surcharge_pct}\n";
    my $bp    = $whole * 100 + substr( ( $places // '' ) . '00', 0, 2 );
    my $total = int( ( $total_cents * ( 10_000 + $bp ) + 5_000 ) / 10_000 );

    my $dates = due_dates( $plan, $first_date );
    my $each  = int( $total / @$dates );
    my $last  = $total - $each * ( @$dates - 1 );
    return [ map { { amount_cents => $_ == $#$dates ? $last : $each, due_date => $dates->[$_] } } 0 .. $#$dates ];
}

# Whether $plan's last payment, the first due on $first_date, falls on or
# before $last_day. ISO dates compare as strings.
sub fits ( $plan, $first_date, $last_day ) {
    return due_dates( $plan, $first_date )->[-1] le $last_day;
}

sub _date ($date) {
    my ( $y, $m, $d ) = $date =~ /\A([0-9]{4})-([0-9]{2})-([0-9]{2})\z/a or die "not a date: $date\n";
    return DateTime->new( year => $y, month => $m, day => $d );
}

sub _plus_days ( $date, $days ) { _date($date)->add( days => $days )->ymd }

# 'limit' keeps the day, or the month's last day when it has fewer.
sub _plus_months ( $date, $months ) { _date($date)->add( months => $months, end_of_month => 'limit' )->ymd }

1;
