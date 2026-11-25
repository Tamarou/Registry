# ABOUTME: Recurring Minion sweep that expires occurrence-bound entitlements once their occurrence has ended.
# ABOUTME: Covers every tenant schema, registry included, and reports per tenant what it expired.
use 5.42.0;
use Object::Pad;

class Registry::Job::ExpireEntitlements {
    use Registry::Job::Recurring;
    use Registry::DAO::Entitlement;

    sub register ($class, $app) {
        Registry::Job::Recurring->add_task( $app, expire_entitlements => sub ($job, @args) {
            $class->new->run($job);
        } );
    }

    method run ($job) {
        my $app     = $job->app;
        my $tenants = $app->dao('registry')->db->select( 'registry.tenants', 'slug' )->arrays->flatten;
        # One broken tenant must not hold up the rest; it is reported by slug, as the other sweeps do.
        my ( @covered, @skipped, %expired );
        for my $slug (@$tenants) {
            try {
                my $ids = Registry::DAO::Entitlement->expire_ended_occurrences( $app->dao($slug)->db );
                $expired{$slug} = $ids if @$ids;
                push @covered, $slug;
            }
            catch ($e) {
                ( my $reason = "$e" ) =~ s/\s+/ /g;
                $app->log->error("expire_entitlements: tenant $slug failed: $reason");
                push @skipped, { slug => $slug, error => $reason };
            }
        }
        return $job->finish( { tenants_covered => \@covered, tenants_skipped => \@skipped, expired => \%expired } );
    }
}
