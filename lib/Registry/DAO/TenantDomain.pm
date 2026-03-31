# ABOUTME: DAO for tenant custom domains. Manages domain-to-tenant mapping,
# ABOUTME: verification status, primary domain selection, and domain validation.
use 5.42.0;
use Object::Pad;

class Registry::DAO::TenantDomain :isa(Registry::DAO::Object) {
    use Carp qw(croak);

    field $id :param :reader;
    field $tenant_id :param :reader;
    field $domain :param :reader;
    field $status :param :reader = 'pending';
    field $is_primary :param :reader = 0;
    field $render_domain_id :param :reader = undef;
    field $verification_error :param :reader = undef;
    field $verified_at :param :reader = undef;
    field $created_at :param :reader = undef;
    field $updated_at :param :reader = undef;

    sub table { 'tenant_domains' }

    sub find_by_domain ($class, $db, $domain) {
        $db = $db->db if $db isa Registry::DAO;
        my $row = $db->select('tenant_domains', '*', { domain => $domain })->hash;
        return $row ? $class->new(%$row) : undef;
    }

    # Returns all domain rows for a tenant. The 1-domain business limit is
    # enforced by the controller, not here. This method returns all rows so
    # future expansion (multiple domains) does not require a DAO change.
    sub for_tenant ($class, $db, $tenant_id) {
        $db = $db->db if $db isa Registry::DAO;
        my @rows = $db->select('tenant_domains', '*', { tenant_id => $tenant_id },
            { -asc => 'created_at' })->hashes->each;
        return map { $class->new(%$_) } @rows;
    }

    sub validate_domain ($class, $domain) {
        return 'Domain is required' unless $domain;
        return 'Invalid domain format'
            unless $domain =~ /\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+\z/i;
        return 'Cannot use IP addresses' if $domain =~ /\A\d+\.\d+\.\d+\.\d+\z/;
        return 'Cannot use localhost' if $domain =~ /\blocalhost\b/i;
        return 'Subdomains of tinyartempire.com are managed automatically'
            if $domain =~ /\.tinyartempire\.com\z/i;
        return undef;  # valid
    }

    # Mark this domain as primary for the tenant. Clears any previous primary
    # and updates tenants.canonical_domain to this domain's name.
    method set_primary ($db) {
        $db = $db->db if $db isa Registry::DAO;

        $db->update('tenant_domains',
            { is_primary => 0 },
            { tenant_id => $tenant_id, is_primary => 1 }
        );

        my $updated = $self->update($db, { is_primary => 1 });
        $is_primary = $updated->is_primary if $updated;

        require Registry::DAO::Tenant;
        my $tenant = Registry::DAO::Tenant->find($db, { id => $tenant_id });
        $tenant->update_canonical_domain($db, $domain) if $tenant;

        return $self;
    }

    # Mark domain as verified. If it is also primary, updates
    # tenants.canonical_domain to reflect the now-active domain.
    method mark_verified ($db) {
        $db = $db->db if $db isa Registry::DAO;
        my $updated = $self->update($db, {
            status             => 'verified',
            verified_at        => \'now()',
            verification_error => undef,
        });

        if ($updated) {
            $status      = $updated->status;
            $verified_at = $updated->verified_at;
        }

        if ($is_primary) {
            require Registry::DAO::Tenant;
            my $tenant = Registry::DAO::Tenant->find($db, { id => $tenant_id });
            $tenant->update_canonical_domain($db, $domain) if $tenant;
        }

        return $self;
    }

    method mark_failed ($db, $error) {
        $db = $db->db if $db isa Registry::DAO;
        my $updated = $self->update($db, {
            status             => 'failed',
            verification_error => $error,
        });

        if ($updated) {
            $status             = $updated->status;
            $verification_error = $updated->verification_error;
        }

        return $self;
    }

    # Remove this domain record. If it was the primary domain, clears
    # tenants.canonical_domain so the tenant reverts to its default subdomain.
    method remove ($db) {
        $db = $db->db if $db isa Registry::DAO;

        if ($is_primary) {
            require Registry::DAO::Tenant;
            my $tenant = Registry::DAO::Tenant->find($db, { id => $tenant_id });
            $tenant->update_canonical_domain($db, undef) if $tenant;
        }

        $db->delete('tenant_domains', { id => $id });
        return 1;
    }
}

1;
