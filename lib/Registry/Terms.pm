# ABOUTME: Which version of the platform's terms /terms states, and whether it is still the DRAFT placeholder.
# ABOUTME: Checkout is refused under the placeholder outside development and test; a booker's agreement records VERSION.
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

# record_agreement($db, $run, $form) -> refusal | undef
#
# The agreement step: $form ticks agree_to_terms and names, in
# terms_version_shown, the version the page showed. Records VERSION, never the
# form's value, as the run's server-owned agreed_terms_version; the booking is
# stamped from it at insert. Refused, recording nothing, when the box is not
# ticked or the version shown is no longer the one /terms serves.
sub record_agreement ( $db, $run, $form ) {
    return 'Agree to the terms of service to book.' unless $form->{agree_to_terms};
    my $shown = $form->{terms_version_shown};
    return 'The terms of service changed while this page was open. Read them again, then agree.'
        unless defined $shown && !ref $shown && $shown eq VERSION;
    $run->update_data( $db, { agreed_terms_version => VERSION } );
    return undef;
}

1;
