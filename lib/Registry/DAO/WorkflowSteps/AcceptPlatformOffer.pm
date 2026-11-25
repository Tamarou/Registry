# ABOUTME: platform-offer-acceptance step: the tenant whose schema the run is in accepts the chosen platform offer.
# ABOUTME: Calls Entitlement->accept in registry with this tenant as holder; never a holder, version or plan from the form.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::AcceptPlatformOffer :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Entitlement;
    use Registry::DAO::Tenant;
    use Registry::DAO::WorkflowSteps::ChoosePlatformOffer;

    method process ( $db, $form_data, $run = undef ) {
        return { stay => 1 } unless ( $form_data->{action} // '' ) eq 'accept';

        # The holder is the tenant whose schema this run is in, and the run's
        # user, seeded server-side, must be its admin: the role gate does not
        # cover a workflow composed around this step.
        my $data = $run->data;
        my $user = ref $data->{user} eq 'HASH' ? $data->{user} : {};
        my $slug = $db->query('SELECT current_schema()')->array->[0];
        return { stay => 1, errors => ["Only an administrator of this tenant can accept the platform's terms."] }
            unless ( Registry::DAO::Tenant->role_in( $db, $slug, $user->{id} ) // '' ) eq 'admin';
        my $tenant_id = $db->query( 'SELECT id FROM registry.tenants WHERE slug = ?', $slug )->array
            or return { stay => 1, errors => ['This tenant cannot accept platform terms.'] };

        # Re-read from the listing; accept re-checks it is current under a lock.
        my $offer = Registry::DAO::WorkflowSteps::ChoosePlatformOffer->listed( $db, $data->{platform_offer_version} )
            or return { stay => 1, errors => ['That plan is not on offer now. Go back and choose one of the plans listed.'] };

        # accept reads and writes unqualified tables: registry's, for this
        # transaction only, then this tenant's again.
        my $tx   = $db->dbh->{AutoCommit} ? $db->begin : undef;
        my $path = $db->query('SHOW search_path')->array->[0];
        $db->query(q{SELECT set_config('search_path', 'registry, public', true)});
        my $entitlement = eval {
            Registry::DAO::Entitlement->accept( $db, {
                holder_tenant_id => $tenant_id->[0],
                offer_version_id => $offer->{id},
                payment_plan_id  => $offer->{plan_id},
            } );
        };
        my $refused = $@;
        die $refused unless $entitlement || $refused isa Registry::DAO::Entitlement::Refused;
        $db->query( q{SELECT set_config('search_path', ?, true)}, $path );
        return { stay => 1, errors => [ $refused->message =~ s/\s+\z//r ] } unless $entitlement;
        $tx->commit if $tx;

        return { platform_entitlement_id => $entitlement->id, platform_offer_name => $offer->{name} };
    }

    method prepare_template_data ( $db, $run, $params = {} ) {
        return { offer => Registry::DAO::WorkflowSteps::ChoosePlatformOffer->listed( $db, $run->data->{platform_offer_version} ) };
    }
}

1;
