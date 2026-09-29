# ABOUTME: Display-only 'complete' step for the tenant-signup workflow.
# ABOUTME: Provisioning happens at payment-time in TenantPayment; this step confirms success.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::RegisterTenant :isa(Registry::DAO::WorkflowStep) {

use Registry::DAO::Workflow;
use Registry::Utility::BaseDomain ();
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

    return {
        tenant            => $data->{tenant},
        organization_name => $data->{organization_name},
        subdomain         => $data->{subdomain},
        admin_email       => $data->{admin_email},
        tenant_url        => Registry::Utility::BaseDomain::tenant_url( $data->{subdomain} // '' ),
        success_timestamp => $data->{success_timestamp} || DateTime->now->iso8601(),
    };
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

# The completion page used to be told a trial_end_date, invented as "30 days
# from now" whenever none was stored. Solo has no trial and no end date, so the
# page now states the plan instead -- read from the same resolver that decided
# which plan the tenant was provisioned onto, rather than from a literal.
method prepare_completion_data($db, $run) {
    my $raw_data = $run->data || {};
    my $subdomain = $raw_data->{subdomain};

    return {
        organization_name => $raw_data->{organization_name} || $raw_data->{name} || 'organization',
        subdomain         => $subdomain,
        tenant_url        => Registry::Utility::BaseDomain::tenant_url( $subdomain // '' ),
        admin_email       => $raw_data->{admin_email},
        admin_name        => $raw_data->{admin_name},
        billing_email     => $raw_data->{billing_email},
        plan              => $self->_plan_summary($db, $run),
    };
}

# Read from the row that governs the charge -- tenants.platform_pricing_plan_id
# -- rather than from a resolver the page would have to trust separately. What
# the confirmation states is then what the tenant will actually be billed.
method _plan_summary ($db, $run) {
    my $tenant_id = ( $run->data || {} )->{tenant} or return {};

    my $row = $db->query(q{
        SELECT p.plan_name,
               p.amount_cents,
               p.pricing_configuration->>'percentage' AS pct
          FROM registry.tenants t
          JOIN registry.pricing_plans p ON p.id = t.platform_pricing_plan_id
         WHERE t.id = ?
    }, $tenant_id)->hash or return {};

    return {
        plan_name             => $row->{plan_name},
        monthly_amount        => $row->{amount_cents},
        revenue_share_percent => ( $row->{pct} // 0 ) * 100,
    };
}

}