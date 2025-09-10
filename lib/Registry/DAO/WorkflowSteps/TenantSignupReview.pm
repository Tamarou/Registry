use 5.40.2;
use utf8;
use Object::Pad;

class Registry::DAO::WorkflowSteps::TenantSignupReview :isa(Registry::DAO::WorkflowStep) {

    # Override template data preparation for tenant signup review steps
    method prepare_template_data ($db, $run) {
        my $raw_data = $run->data || {};
        
        # Structure the data for the review template
        return {
            profile => {
                name => $raw_data->{name} || $raw_data->{organization_name},
                subdomain => $raw_data->{subdomain},
                description => $raw_data->{description},
                billing_email => $raw_data->{billing_email},
                billing_phone => $raw_data->{billing_phone},
                billing_address => $raw_data->{billing_address},
                billing_address2 => $raw_data->{billing_address2},
                billing_city => $raw_data->{billing_city},
                billing_state => $raw_data->{billing_state},
                billing_zip => $raw_data->{billing_zip},
                billing_country => $raw_data->{billing_country},
            },
            team => {
                admin => {
                    name => $raw_data->{admin_name},
                    email => $raw_data->{admin_email},
                    username => $raw_data->{admin_username},
                },
                team_members => $raw_data->{team_members} || [],
            },
        };
    }

    method process($db, $form_data) {
        # Basic review step processing - mostly just validation
        my $workflow = $self->workflow($db);
        my $run = $workflow->latest_run($db);
        
        # This step doesn't modify data, it just validates that required 
        # information is present before proceeding to the next step
        return {};
    }
}