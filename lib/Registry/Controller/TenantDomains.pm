# ABOUTME: Controller for admin-only custom domain management. Handles listing,
# ABOUTME: adding, verifying, setting primary, and removing tenant custom domains.
use 5.42.0;
use utf8;
use Object::Pad;

class Registry::Controller::TenantDomains :isa(Registry::Controller) {
    use Registry::DAO;
    use Registry::DAO::TenantDomain;
    use Registry::DAO::Tenant;

    # Returns a DAO connected to the registry schema where tenant_domains
    # and tenants live. Uses the dao helper so tests can override it.
    method _registry_dao {
        return $self->dao('registry');
    }

    # GET /admin/domains — list all domains for the current tenant
    method index {
        my $tenant_slug = $self->tenant;
        my $dao = $self->_registry_dao;
        my $db  = $dao->db;

        my $tenant = Registry::DAO::Tenant->find($db, { slug => $tenant_slug });
        unless ($tenant) {
            return $self->render(text => 'Tenant not found', status => 404);
        }

        my @domains = Registry::DAO::TenantDomain->for_tenant($db, $tenant->id);

        $self->stash(domains => \@domains, tenant => $tenant);
        $self->render(template => 'admin/domains/index');
    }

    # POST /admin/domains — add a new custom domain for the current tenant
    method add {
        my $domain_name = $self->param('domain');
        my $tenant_slug = $self->tenant;
        my $dao = $self->_registry_dao;
        my $db  = $dao->db;

        my $tenant = Registry::DAO::Tenant->find($db, { slug => $tenant_slug });
        unless ($tenant) {
            return $self->render(text => 'Tenant not found', status => 404);
        }

        # Validate domain format
        if (my $error = Registry::DAO::TenantDomain->validate_domain($domain_name)) {
            return $self->render(
                template => 'admin/domains/index',
                domains  => [Registry::DAO::TenantDomain->for_tenant($db, $tenant->id)],
                tenant   => $tenant,
                error    => $error,
                status   => 422,
            );
        }

        # Enforce 1-domain limit per tenant
        my @existing = Registry::DAO::TenantDomain->for_tenant($db, $tenant->id);
        if (@existing) {
            return $self->render(
                template => 'admin/domains/index',
                domains  => \@existing,
                tenant   => $tenant,
                error    => 'This tenant already has a custom domain. Remove the existing domain before adding a new one.',
                status   => 422,
            );
        }

        # Check for duplicate domain across all tenants
        if (Registry::DAO::TenantDomain->find_by_domain($db, $domain_name)) {
            return $self->render(
                template => 'admin/domains/index',
                domains  => \@existing,
                tenant   => $tenant,
                error    => 'This domain is already registered.',
                status   => 422,
            );
        }

        # Register with Render API
        my $render_result = eval {
            $self->app->render_service->add_custom_domain($domain_name);
        };
        if ($@) {
            $self->app->log->warn("Render API add_custom_domain failed: $@");
        }

        my $render_domain_id = $render_result ? $render_result->{id} : undef;

        # Create the database record
        Registry::DAO::TenantDomain->create($db, {
            tenant_id        => $tenant->id,
            domain           => $domain_name,
            status           => 'pending',
            render_domain_id => $render_domain_id,
        });

        # Render DNS instructions with passkey re-registration warning
        $self->stash(
            domain          => $domain_name,
            passkey_warning => 1,
        );
        $self->render(template => 'admin/domains/dns_instructions');
    }

    # POST /admin/domains/:id/verify — trigger DNS verification for a domain
    method verify {
        my $id  = $self->param('id');
        my $dao = $self->_registry_dao;
        my $db  = $dao->db;

        my $td = Registry::DAO::TenantDomain->find($db, { id => $id });
        unless ($td) {
            return $self->render(text => 'Domain not found', status => 404);
        }

        eval {
            if ($td->render_domain_id) {
                my $result = $self->app->render_service->verify_custom_domain($td->render_domain_id);
                if ($result && ($result->{verificationStatus} // '') eq 'confirmed') {
                    $td->mark_verified($db);
                } else {
                    my $err = $result ? ($result->{verificationError} // 'Verification pending') : 'Verification pending';
                    $td->mark_failed($db, $err);
                }
            } else {
                # No render_domain_id — mark as failed with explanation
                $td->mark_failed($db, 'Domain not registered with Render');
            }
        };
        if ($@) {
            $self->app->log->warn("Render verify_custom_domain failed: $@");
            $td->mark_failed($db, $@);
        }

        $self->redirect_to('/admin/domains');
    }

    # POST /admin/domains/:id/primary — make a domain the primary for the tenant
    method set_primary {
        my $id  = $self->param('id');
        my $dao = $self->_registry_dao;
        my $db  = $dao->db;

        my $td = Registry::DAO::TenantDomain->find($db, { id => $id });
        unless ($td) {
            return $self->render(text => 'Domain not found', status => 404);
        }

        $td->set_primary($db);
        $self->redirect_to('/admin/domains');
    }

    # DELETE /admin/domains/:id — remove a custom domain
    method remove {
        my $id  = $self->param('id');
        my $dao = $self->_registry_dao;
        my $db  = $dao->db;

        my $td = Registry::DAO::TenantDomain->find($db, { id => $id });
        unless ($td) {
            return $self->render(text => 'Domain not found', status => 404);
        }

        # Remove from Render if we have a render_domain_id
        if ($td->render_domain_id) {
            eval { $self->app->render_service->remove_custom_domain($td->render_domain_id) };
            if ($@) {
                $self->app->log->warn("Render remove_custom_domain failed: $@");
            }
        }

        $td->remove($db);
        $self->redirect_to('/admin/domains');
    }
}

1;
