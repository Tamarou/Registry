use 5.42.0;
use utf8;
use Object::Pad;

class Registry::DAO::WorkflowSteps::TenantSignupReview :isa(Registry::DAO::WorkflowStep) {

    # Override template data preparation for tenant signup review steps
    method prepare_template_data ($db, $run, $params = {}) {
        my $raw_data = $run->data || {};
        
        # Structure the data for the review template
        my $selected_plan = $raw_data->{selected_pricing_plan} || {};

        return {
            profile => {
                name => $raw_data->{name} || $raw_data->{organization_name},
                subdomain => $raw_data->{subdomain},
                description => $raw_data->{description},
                billing_email => $raw_data->{billing_email},
            },
            team => {
                admin => {
                    name => $raw_data->{admin_name},
                    email => $raw_data->{admin_email},
                    username => $raw_data->{admin_username},
                },
                team_members => $raw_data->{team_members} || [],
            },
            selected_plan => $selected_plan,
        };
    }

    method process($db, $form_data, $run = undef) {
        $run //= do { my $w = $self->workflow($db); $w->latest_run($db) };
        # Basic review step processing - mostly just validation
        
        # This step doesn't modify data, it just validates that required 
        # information is present before proceeding to the next step
        return {};
    }
}