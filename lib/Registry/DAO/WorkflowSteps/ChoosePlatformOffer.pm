# ABOUTME: platform-offer-acceptance step: an existing tenant's admin chooses one of the platform's current offers to tenants.
# ABOUTME: Only a listed offer (platform_offers_to_tenants, as signup lists them) is taken; a tenant already holding terms is told so.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::ChoosePlatformOffer :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::WorkflowSteps::PublishOfferVersion;
    use Registry::PriceOps::PlatformTerms qw( platform_offers_to_tenants platform_terms_for_tenant );

    # The listed platform offer whose version id is $id, with its rate as a
    # percent for the screen; undef for anything not listed now: an unpublished,
    # superseded or another tenant's version.
    sub listed ( $class, $db, $id ) {
        my ($offer) = grep { $_->{id} eq ( $id // '' ) } platform_offers_to_tenants($db)->@*;
        return $offer && { %$offer, rate => Registry::DAO::WorkflowSteps::PublishOfferVersion->percent_of( $offer->{fraction} ) };
    }

    method process ( $db, $form_data, $run = undef ) {
        my $offer = __PACKAGE__->listed( $db, ref $form_data->{offer_version} ? undef : $form_data->{offer_version} )
            or return { stay => 1, errors => ['Please choose one of the plans listed.'] };
        return { platform_offer_version => $offer->{id} };
    }

    # The tenant's platform terms now, with their rate as a percent; undef when
    # it holds none, the one refusal that means nothing is held. Any other error dies.
    method _held ( $db, $slug ) {
        my $terms = eval { platform_terms_for_tenant( $db, $slug ) };
        unless ($terms) {
            return undef if $@ =~ /\ATenant '\Q$slug\E' holds no platform entitlement /;
            die $@;
        }
        return { %$terms, rate => Registry::DAO::WorkflowSteps::PublishOfferVersion->percent_of( $terms->{fraction} ) };
    }

    method prepare_template_data ( $db, $run, $params = {} ) {
        my $slug = $db->query('SELECT current_schema()')->array->[0];
        return {
            offers => [ map { __PACKAGE__->listed( $db, $_->{id} ) } platform_offers_to_tenants($db)->@* ],
            held => $self->_held( $db, $slug ),
        };
    }
}

1;
