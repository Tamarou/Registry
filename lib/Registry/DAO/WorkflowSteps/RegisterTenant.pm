# ABOUTME: Display-only 'complete' step for the tenant-signup workflow.
# ABOUTME: Provisioning happens at payment-time in TenantPayment; this step confirms success.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::RegisterTenant :isa(Registry::DAO::WorkflowStep) {

use Registry::DAO::Workflow;
use Carp qw(croak);
use DateTime;

# process: the tenant was already provisioned by TenantPayment during the
# payment POST.  This step is display-only: it reads the stored tenant info
# from run data and returns it for the completion template.  If tenant info
# is missing (unexpected), it raises an error so the bug is visible.
method process ( $db, $, $run = undef ) {
    $run //= do { my ($w) = $self->workflow($db); $w->latest_run($db) };

    my $data = $run->data;

    croak 'Tenant was not provisioned before the complete step'
        unless $data->{tenant};

    if ( $run->has_continuation ) {
        my ($continuation) = $run->continuation($db);
        my $tenants = $continuation->data->{tenants} // [];
        push $tenants->@*, $data->{tenant};
        $continuation->update_data( $db, { tenants => $tenants } );
    }

    my $subscription_data = $data->{subscription} || {};
    return {
        tenant            => $data->{tenant},
        organization_name => $data->{organization_name},
        subdomain         => $data->{subdomain},
        admin_email       => $data->{admin_email},
        trial_end_date    => $self->_format_trial_end_date($subscription_data->{trial_ends_at}),
        success_timestamp => $data->{success_timestamp} || DateTime->now->iso8601(),
    };
}

method _format_trial_end_date($trial_ends_at) {
    return 'N/A' unless $trial_ends_at;
    
    # Parse the timestamp (could be Unix timestamp)
    my $dt;
    if ($trial_ends_at =~ /^\d+$/) {
        # Unix timestamp
        $dt = DateTime->from_epoch(epoch => $trial_ends_at);
    } else {
        # For now, just return the raw value if not a unix timestamp
        # In a production system, we'd add proper ISO date parsing
        return $trial_ends_at;
    }
    
    # Format as human-readable date
    return $dt->strftime('%B %d, %Y');
}

# Override template data preparation for RegisterTenant steps
method prepare_template_data ($db, $run, $params = {}) {
    # If this is a completion step, use our specialized completion data
    my $step_slug = $self->slug || '';
    if ($step_slug eq 'complete') {
        return $self->prepare_completion_data($db, $run);
    }
    
    # For other RegisterTenant steps, use default behavior
    return $self->SUPER::prepare_template_data($db, $run);
}

method prepare_completion_data($db, $run) {
    my $raw_data = $run->data || {};

    # Prefer the stored trial end date from subscription data; fall back to 30 days.
    my $subscription_data = $raw_data->{subscription} || {};
    my $trial_end_date = $self->_format_trial_end_date($subscription_data->{trial_ends_at});
    unless ($trial_end_date && $trial_end_date ne 'N/A') {
        $trial_end_date = DateTime->now->add(days => 30)->strftime('%B %d, %Y');
    }

    return {
        organization_name => $raw_data->{organization_name} || $raw_data->{name} || 'organization',
        subdomain         => $raw_data->{subdomain},
        admin_email       => $raw_data->{admin_email},
        admin_name        => $raw_data->{admin_name},
        trial_end_date    => $trial_end_date,
        billing_email     => $raw_data->{billing_email},
    };
}

}