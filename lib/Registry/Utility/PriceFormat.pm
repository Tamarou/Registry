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
    my $suffix = $opts{suffix} // '';

    # Show cents only when there are any: a $200/month plan should read "$200",
    # but a $19.99 one must not be quoted as "$20".
    my $format = $amount_cents % 100 ? '%.2f' : '%.0f';
    my $amount = sprintf($format, $amount_cents / 100);

    return "\$$amount$suffix" if uc($currency) eq 'USD';

    return "$amount " . uc($currency) . $suffix;
}

1;
