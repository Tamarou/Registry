# ABOUTME: Which version of the platform's terms /terms states, and whether it is still the DRAFT placeholder.
# ABOUTME: While it is, checkout is refused in every mode but development and test (ADR 005, ruling 12).
package Registry::Terms;
use 5.42.0;

# Names the text in templates/terms.html.ep. 'draft' is the placeholder; the
# issue that puts perigrin's text in that template changes this with it.
use constant VERSION => 'draft';

sub is_placeholder () { VERSION eq 'draft' }

# checkout_refusal($mode) -> message | undef
#
# Production is every mode but development and test, as the session cookie
# reads it; $mode defaults to the one Mojolicious would pick, falling back to
# development as Mojolicious does when neither MOJO_MODE nor PLACK_ENV is set.
sub checkout_refusal ( $mode = $ENV{MOJO_MODE} || $ENV{PLACK_ENV} || 'development' ) {
    return undef unless is_placeholder();
    return undef if $mode eq 'development' || $mode eq 'test';
    return 'Checkout is closed until the terms of service are final. Nothing has been charged.';
}

1;
