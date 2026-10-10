# ABOUTME: Minion background job that periodically checks pending custom domains
# ABOUTME: via the Render API and updates their verification status.
use 5.42.0;
use Object::Pad;

class Registry::Job::DomainVerification {
    use Registry::DAO::TenantDomain;
    use Registry::Service::Render;

    # Register this job with Minion
    sub register ($class, $app) {
        $app->minion->add_task(domain_verification => sub ($job, @args) {
            $class->new->run($job, @args);
        });
    }

    # Main job execution method - fetches db and render client, then delegates
    method run ($job, @args) {
        my $db = $job->app->dao('registry')->db;
        my $render = Registry::Service::Render->new(
            api_key    => $ENV{RENDER_API_KEY},
            service_id => $ENV{RENDER_SERVICE_ID},
        );
        $self->check_pending_domains($db, $render);
    }

    # How long a domain is given to propagate before we call it a day. DNS
    # routinely takes longer than one poll interval, and often longer than an
    # hour.
    use constant VERIFICATION_WINDOW_DAYS => 7;

    # check_pending_domains is a separate method to allow direct unit testing
    # without a full Minion job context.
    #
    # THREE outcomes, not two. This previously marked a domain `failed` on any
    # result that was not `confirmed` -- including Render's own "still waiting
    # for DNS" -- and then stopped looking at it, because the query selects
    # status = 'pending'. So a domain whose records were correct but had not
    # propagated yet was failed on the first poll, minutes after the tenant
    # added it, and never checked again. Verification was effectively
    # single-shot and the manual button was the only way back.
    #
    # That also made a notification impossible to send honestly, which is why
    # it is fixed here rather than separately (#21): "your domain failed" is the
    # wrong thing to email somebody whose DNS is simply still spreading.
    method check_pending_domains ($db, $render) {
        my @pending = $db->select(
            'tenant_domains', '*', { status => 'pending' }
        )->hashes->map(sub { Registry::DAO::TenantDomain->new(%$_) })->each;

        for my $td (@pending) {
            next unless $td->render_domain_id;

            # Out of time. Terminal, and said out loud -- a domain that simply
            # stopped being polled told the tenant nothing at all, which is the
            # defect this whole unit exists to fix.
            if ( $self->_past_window( $db, $td ) ) {
                $td->mark_failed( $db, sprintf(
                    'Not verified within %d days. The DNS records may not have '
                      . 'been added, or may not match what this page shows.',
                    VERIFICATION_WINDOW_DAYS ) );
                $self->_tell_the_tenant( $db, $td, 0 );
                next;
            }

            my $result = eval { $render->verify_custom_domain($td->render_domain_id) };

            # A thrown error is a real failure -- a bad credential, a domain
            # Render has never heard of, the API refusing. Terminal.
            if ( my $err = $@ ) {
                $err =~ s/\s+$//;
                $td->mark_failed( $db, $err );
                $self->_tell_the_tenant( $db, $td, 0 );
                next;
            }

            if ( $result && ( $result->{verificationStatus} // '' ) eq 'confirmed' ) {
                $td->mark_verified($db);
                $self->_tell_the_tenant( $db, $td, 1 );
                next;
            }

            # Everything else is "not yet". The row STAYS pending so the next
            # run looks again, and the reason is recorded so the admin page can
            # show what Render is waiting for rather than a bare spinner.
            my $reason = $result && $result->{verificationError};
            $td->note_still_pending( $db, $reason ) if $reason;
        }
    }

    method _past_window ( $db, $td ) {
        return $db->query(
            q{SELECT created_at < now() - ($1 || ' days')::interval AS past
                FROM tenant_domains WHERE id = $2},
            VERIFICATION_WINDOW_DAYS, $td->id
        )->hash->{past} ? 1 : 0;
    }

    # Queued in the TENANT's schema, because it is that tenant's news and
    # SendNotifications sweeps every tenant. Never fatal: a notification that
    # cannot be queued must not leave the domain's own status unwritten.
    method _tell_the_tenant ( $db, $td, $verified ) {
        require Registry::DAO::Tenant;
        require Registry::DAO::Notification;

        # Resolved OUTSIDE the eval, so "there is nobody to tell" is reported as
        # itself rather than as a failure. An early return inside an eval leaves
        # $@ empty, and both conditions then arrive as "unknown error" -- which
        # is what the first version of this did.
        my ($tenant) = Registry::DAO::Tenant->find( $db, { id => $td->tenant_id } );
        unless ($tenant) {
            warn "DomainVerification: no tenant for domain " . $td->domain . "\n";
            return;
        }

        my $admin = $tenant->primary_user($db);
        unless ($admin) {
            # A tenant with no primary user has nobody to address. Said out
            # loud: the fleet screen treats a missing resident owner as a
            # provisioning fault (#426), and this is the same fault surfacing.
            warn "DomainVerification: tenant " . $tenant->slug
               . " has no primary user to tell about " . $td->domain . "\n";
            return;
        }

        eval {

            # The tenant's own schema, reached the way every other tenant-scoped
            # write does.
            my $tenant_db = Registry::DAO->new( url => $ENV{DB_URL} )
                ->connect_schema( $tenant->slug )->db;

            Registry::DAO::Notification->ensure_domain_outcome( $tenant_db, {
                user_id     => $admin->id,
                domain      => $td->domain,
                verified    => $verified,
                tenant_name => $tenant->name,
                error       => $td->verification_error,
                retry_url   => ( $ENV{BASE_URL} // '' ) . '/admin/domains',
            } );
            1;
        } or do {
            my $err = $@ || 'unknown error';
            $err =~ s/\s+/ /g;
            warn "DomainVerification: could not queue the outcome for "
               . $td->domain . ": $err\n";
        };
    }
}

1;
