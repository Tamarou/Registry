# ABOUTME: Tests that the shared price formatter renders whole cents faithfully.
# ABOUTME: Rounding a price to the dollar misquotes what the customer will be charged.
use 5.42.0;
use Test::More;

use Registry::Utility::PriceFormat qw(format_price);

subtest 'whole dollars stay clean' => sub {
    is format_price(20000, 'USD'), '$200', 'a round price does not grow decimals';
    is format_price(0, 'USD'), '$0', 'free is free';
};

subtest 'cents survive' => sub {
    is format_price(1999, 'USD'), '$19.99', 'a price with cents keeps them';
    is format_price(2001, 'USD'), '$20.01', 'and does not round down to the dollar';
    is format_price(5, 'USD'), '$0.05', 'a nickel is not zero';
};

subtest 'other currencies follow the same rule' => sub {
    is format_price(1999, 'eur'), '19.99 EUR', 'cents kept, currency upcased';
    is format_price(20000, 'eur'), '200 EUR', 'round stays round';
};

subtest 'suffixes still attach' => sub {
    is format_price(1999, 'USD', suffix => '/month'), '$19.99/month',
        'the suffix follows the amount';
};

subtest 'an undefined amount is free, not a warning' => sub {
    is format_price(undef, 'USD'), '$0', 'undef reads as zero';
};

done_testing;
