# ABOUTME: Workflow step for choosing a platform offer during tenant signup; no shipped workflow uses it.
# ABOUTME: Lists the platform's published offers to tenants and carries the chosen version.

use 5.42.0;

use Object::Pad;

class Registry::DAO::WorkflowSteps::PricingPlanSelection :isa(Registry::DAO::WorkflowStep) {
    use Carp qw(croak);
    use Registry::Utility::PriceFormat qw(format_price);
    use Registry::PriceOps::PlatformTerms qw(platform_offers_to_tenants);

    method process($db, $form_data, $run = undef) {
        # Check if plan selection was submitted
        unless (exists $form_data->{selected_plan_id}) {
            # Show plan selection page (unless we're in auto-select mode for workflow testing)
            my $pricing_data = $self->prepare_pricing_data($db);
            my $pricing_plans = $pricing_data->{pricing_plans} || [];

            # When no plans are configured, skip this step entirely --
            # there is nothing for the user to select.
            unless (@$pricing_plans) {
                return {};
            }

            # Auto-select the first plan when explicitly requested
            if (exists $form_data->{__auto_select_plan}) {
                $form_data->{selected_plan_id} = $pricing_plans->[0]->{id};
                # Continue processing with auto-selected plan
            } else {
                # Show plan selection page
                return {
                    next_step => $self->id,
                    data => $pricing_data
                };
            }
        }

        # Validate and process plan selection
        my $selected_plan_id = $form_data->{selected_plan_id};

        # Check for empty or invalid plan ID
        if (!$selected_plan_id || $selected_plan_id eq '') {
            return {
                _validation_errors => ['Please select a pricing plan.'],
            };
        }

        # Validate plan exists and is available
        my $selected_plan = $self->validate_plan_selection($db, $selected_plan_id);

        if (!$selected_plan) {
            return {
                _validation_errors => ['The selected pricing plan is not available.'],
            };
        }

        # The version id only, under the server-owned key signup provisions
        # from; its terms are re-read wherever they are quoted or granted.
        return { selected_offer_version => $selected_plan->{id} };
    }

    # Provide pricing plans and org info to the template via the controller's
    # standard prepare_template_data interface
    method prepare_template_data($db, $run, $params = {}) {
        return $self->prepare_pricing_data($db, $run);
    }

    # The platform's published offers to tenants, in the shape the plan
    # template renders: the offer's name, the version's price and its
    # percentage-of-sales rate as pricing_configuration's percentage.
    method prepare_pricing_data($db, $run = undef) {
        return {
            pricing_plans => $self->_plans($db),
            organization_info => $self->get_organization_preview($db, $run)
        };
    }

    method _plans ($db) {
        return [ map { +{
            id                    => $_->{id},
            plan_name             => $_->{name},
            amount_cents          => $_->{amount_cents},
            currency              => $_->{currency},
            pricing_configuration => { percentage => $_->{fraction} },
            metadata              => {},
            formatted_price       => format_price( $_->{amount_cents}, $_->{currency} ),
        } } platform_offers_to_tenants($db)->@* ];
    }

    # The chosen offer if it is a current published platform offer to tenants.
    method validate_plan_selection($db, $plan_id) {
        my ($plan) = grep { $_->{id} eq ( $plan_id // '' ) } $self->_plans($db)->@*;
        return $plan;
    }

    method get_organization_preview($db, $run = undef) {
        unless ($run) {
            my $workflow = $self->workflow($db);
            $run = $workflow->latest_run($db);
        }
        my $data = $run ? ($run->data || {}) : {};

        return {
            organization_name => $data->{name} || $data->{organization_name} || 'Your Organization',
            admin_email => $data->{admin_email} || $data->{billing_email} || '',
            subdomain => $data->{subdomain} || ''
        };
    }

    method template { 'tenant-signup/pricing' }
}