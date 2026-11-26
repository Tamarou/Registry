# ABOUTME: Which version of the platform's terms /terms states, effective 2026-11-26.
# ABOUTME: A booker's agreement records VERSION on the run, and the booking is stamped from it.
package Registry::Terms;
use 5.42.0;

# Names the text in templates/terms.html.ep: change it with that text.
use constant VERSION => '2026-11-26';

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
