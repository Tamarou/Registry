# ABOUTME: offer-publishing step: review the terms the run collected and publish them as an offer version.
# ABOUTME: Admin of the run's tenant only, one version per run; once published the database keeps it immutable.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::PublishOfferVersion :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Offer;
    use Registry::DAO::Project;
    use Registry::DAO::Resource;
    use Registry::DAO::Tenant;
    use Registry::Utility::PriceFormat qw( format_price );

    method process ( $db, $form_data, $run = undef ) {
        return { stay => 1 } unless ( $form_data->{action} // '' ) eq 'publish';

        # The run's user, which the controller seeds server-side, never the
        # form's; and their role in the tenant whose schema the run is in.
        # The per-slug role gate does not cover a workflow staff composed
        # around this step themselves, so the step checks for itself.
        my $data   = $run->data;
        my $user   = ref $data->{user} eq 'HASH' ? $data->{user} : {};
        my $tenant = $db->query('SELECT current_schema()')->array->[0];
        return { stay => 1, errors => ['Only an administrator of this tenant can publish an offer'] }
            unless ( Registry::DAO::Tenant->role_in( $db, $tenant, $user->{id} ) // '' ) eq 'admin';

        my ( $basic, $price ) = $data->@{qw( offer_basics offer_price )};
        return { stay => 1, errors => ['Complete the offer and price steps before publishing'] }
            unless ref $basic eq 'HASH' && ref $price eq 'HASH';

        # Refused, never defaulted: absence is not a refund policy.
        return { stay => 1, errors => ['Choose a refund policy'] }
            unless ( $form_data->{refund} // '' ) eq 'none';

        # From the run, as the use-policy step recorded it, never this form.
        my $use = ( ref $data->{use_policy} eq 'HASH' ? $data->{use_policy} : {} )->{use};
        return { stay => 1, errors => ['Choose a use policy before publishing'] }
            unless defined $use && !ref $use;

        # One version per run: the run's row is locked while this reads whether
        # it has published, so a repeated or concurrent submission waits and
        # then finds the first one's version instead of publishing another.
        # Every plan a payment step declared; refused, never defaulted, when
        # none did: absence is not zero.
        my $percentage = $data->{percentage_of_sales_payment} // {};
        my @plans = (
            ( ( $data->{one_time_payment} // {} )->{one_time} // '' ) eq 'offered'
                ? { id => 'one_time', kind => 'one_time' } : (),
            ( $percentage->{percentage_of_sales} // '' ) eq 'offered'
                ? { id => 'percentage_of_sales', kind => 'percentage_of_sales', fraction => $percentage->{fraction} } : (),
        );
        return { stay => 1, errors => ['Offer at least one payment plan'] } unless @plans;

        my $tx = $db->dbh->{AutoCommit} ? $db->begin : undef;
        my $published = $db->query( q{
            SELECT data->>'published_offer_version_id' FROM workflow_runs WHERE id = ? FOR UPDATE
        }, $run->id )->array->[0];
        return { published_offer_version_id => $published } if $published;

        my $version = eval {
            Registry::DAO::Offer->create( $db, { name => $basic->{offer_name} } )->draft( $db, {
                $basic->%{qw( resource_id class_project_id )},    # one or the other
                $price->%{qw( price_cents currency units_per_acceptance per_booking_cap )},
                payment_plans => \@plans,
                policies => { refund => { kind => 'none' }, use => { kind => $use } },
            } )->publish($db);
        };
        unless ($version) {
            my $why = $@ =~ s/ at \S+ line \d+\.?\n?\z//r;
            return { stay => 1, errors => ["Could not publish: $why"] };
        }
        $run->update_data( $db, { published_offer_version_id => $version->id } );
        $tx->commit if $tx;

        return { published_offer_version_id => $version->id };
    }

    method prepare_template_data ( $db, $run, $params = {} ) {
        my $data  = $run->data;
        my $price = $data->{offer_price} // {};
        my $basic = $data->{offer_basics} // {};
        my ( $id, $class_id ) = $basic->@{qw( resource_id class_project_id )};
        return {
            %$data,
            resource      => $id ? Registry::DAO::Resource->find( $db, { id => $id } ) : undef,
            class         => $class_id ? Registry::DAO::Project->find( $db, { id => $class_id } ) : undef,
            price_display => format_price( $price->{price_cents}, $price->{currency} ),
        };
    }
}

1;
