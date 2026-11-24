# ABOUTME: offer-publishing step: whether the offer is paid for by a percentage of each of the holder's sales.
# ABOUTME: The rate is a percent with at most 2 places, kept as an exact 4-place fraction string, never a float.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::PercentageOfSalesPaymentPlan :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::WorkflowSteps::PublishOfferVersion;

    # The recorded rate, as the percent the form asks for.
    method prepare_template_data ( $db, $run, $params = {} ) {
        my $data     = $run->data || {};
        my $fraction = ( $data->{percentage_of_sales_payment} // {} )->{fraction};
        return { %$data, rate_percent => defined $fraction
                ? Registry::DAO::WorkflowSteps::PublishOfferVersion->percent_of($fraction) =~ s/%\z//r : '' };
    }

    method process ( $db, $form_data, $run = undef ) {
        my $choice = $form_data->{percentage_of_sales} // '';
        return { stay => 1, errors => ['Say whether a percentage of each sale is offered'] }
            unless $choice eq 'offered' || $choice eq 'declined';
        return { percentage_of_sales_payment => { percentage_of_sales => 'declined' } }
            if $choice eq 'declined';

        # Whole basis points, as the database and Stripe's 2-place fee percent
        # take it; refused, never rounded. Integer arithmetic keeps it exact.
        my $rate = $form_data->{rate_percent};
        $rate = '' if ref $rate || !defined $rate;
        my ( $whole, $places ) = $rate =~ /\A([0-9]{1,3})(?:\.([0-9]{1,2}))?\z/
            or return { stay => 1, errors => ['The rate must be a percent from 0 to 100 with at most 2 decimal places, such as 2.5'] };
        my $basis_points = $whole * 100 + substr( ( $places // '' ) . '00', 0, 2 );
        return { stay => 1, errors => ['The rate cannot be more than 100%'] } if $basis_points > 10_000;

        return { percentage_of_sales_payment => {
            percentage_of_sales => 'offered',
            fraction            => sprintf( '%d.%04d', int( $basis_points / 10_000 ), $basis_points % 10_000 ),
        } };
    }
}

1;
