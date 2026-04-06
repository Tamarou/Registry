use 5.42.0;

use Object::Pad;

class Registry::DAO::WorkflowSteps::AttendanceCheck::TenantProcessor :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Tenant;

    method process($db, $continuation, $run = undef) {
        $run //= do { my ($w) = $self->workflow($db); $w->latest_run($db) };
        my $tenants = Registry::DAO::Tenant->get_all_tenant_schemas($db);
        
        # Store tenant list in run data for other steps to process
        my $tenant_slugs = [ map { $_->{slug} } grep { $_->{slug} ne 'registry' } @$tenants ];
        
        $run->update_data($db, {
            tenant_schemas => $tenant_slugs,
            current_tenant_index => 0
        });
        
        return;
    }
}