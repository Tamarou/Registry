# ABOUTME: offer-publishing step: when the offer's entitlement expires, chosen explicitly.
# ABOUTME: Occurrence-bound and class offers expire at the end of the occurrence; any other offer never expires.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::ExpiryPolicy :isa(Registry::DAO::WorkflowStep) {

    # Why $choice no longer fits the offer the run describes, or nothing; publish
    # asks again, since offer-basics can be answered again after this step. A
    # class offer's entitlement holds one of its occurrences, and a resource is
    # bound to one only while its events row is still there.
    sub refusal ( $class, $db, $data, $choice ) {
        my $basic = ref $data->{offer_basics} eq 'HASH' ? $data->{offer_basics} : {};
        my $bound = $basic->{class_project_id} ? 1 : $basic->{resource_id} ? $db->query( q{
            SELECT 1 FROM resources r JOIN events e ON e.id = r.event_id WHERE r.id = ?
        }, $basic->{resource_id} )->rows : 0;
        return 'Only an offer for an occurrence or a class can expire at the end of the occurrence'
            if $choice eq 'end_of_occurrence' && !$bound;
        return 'An offer for an occurrence or a class expires at the end of the occurrence, not never'
            if $choice eq 'never' && $bound;
        return;
    }

    method process ( $db, $form_data, $run = undef ) {
        my $choice = $form_data->{expiry};
        $choice = '' if ref $choice || !defined $choice;
        return { stay => 1, errors => ['Choose an expiry policy: at the end of the occurrence or never'] }
            unless $choice eq 'end_of_occurrence' || $choice eq 'never';

        my $why = __PACKAGE__->refusal( $db, $run ? $run->data : {}, $choice );
        return { stay => 1, errors => [$why] } if $why;
        return { expiry_policy => { expiry => $choice } };
    }
}

1;
