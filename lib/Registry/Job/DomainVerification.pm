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

    # check_pending_domains is a separate method to allow direct unit testing
    # without a full Minion job context.
    method check_pending_domains ($db, $render) {
        my @pending = $db->select(
            'tenant_domains', '*',
            \[ "status = 'pending' AND created_at > now() - interval '7 days'" ]
        )->hashes->map(sub { Registry::DAO::TenantDomain->new(%$_) })->each;

        for my $td (@pending) {
            next unless $td->render_domain_id;
            eval {
                my $result = $render->verify_custom_domain($td->render_domain_id);
                if ($result && ($result->{verificationStatus} // '') eq 'confirmed') {
                    $td->mark_verified($db);
                } else {
                    my $err = $result
                        ? ($result->{verificationError} // 'Verification pending')
                        : 'Verification pending';
                    $td->mark_failed($db, $err);
                }
            };
            if ($@) {
                (my $err = $@) =~ s/\s+$//;
                $td->mark_failed($db, $err);
            }
        }
    }
}

1;
