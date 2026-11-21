# ABOUTME: Shared price formatting utility for currency display across workflow steps.
# ABOUTME: Provides consistent price formatting for PricingPlanSelection and TenantPayment.
use 5.42.0;
use experimental 'signatures';

package Registry::Utility::PriceFormat;

use Exporter 'import';
our @EXPORT_OK = qw(format_price);

sub format_price ($amount_cents, $currency, %opts) {
    $amount_cents //= 0;
    $currency //= 'USD';
    my $amount_dollars = $amount_cents / 100;
    my $suffix = $opts{suffix} // '';

    if (uc($currency) eq 'USD') {
        return sprintf('$%.0f%s', $amount_dollars, $suffix);
    }

    return sprintf('%.0f %s%s', $amount_dollars, uc($currency), $suffix);
}

1;
