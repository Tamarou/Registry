# ABOUTME: Read-only report of how each tenant's copy of the workflows differs from the platform's (registry schema).
# ABOUTME: Compares slugs, step order, step class and template by name and exact content; output is Markdown, one section per tenant.
use 5.42.0;
use experimental 'signatures';

package Registry::WorkflowDivergence;

# Provisioning never copies these to a tenant, so their absence is expected.
my %NOT_COPIED = map { $_ => 1 } qw( tenant-signup registry-storefront );

# Every workflow in $schema (already quoted), by slug.
sub _workflows ( $db, $schema ) {
    return { map { $_->{slug} => $_ }
          $db->query("SELECT id, slug, first_step FROM $schema.workflows")->hashes->each };
}

sub _differences ( $db, $tenant ) {
    my $platform = _workflows( $db, 'registry' );
    my $copy     = _workflows( $db, $db->dbh->quote_identifier($tenant) );

    my @lines;
    for my $slug ( sort keys %$copy ) {
        push @lines, "- `$slug`: only in the tenant" unless $platform->{$slug};
    }
    for my $slug ( sort keys %$platform ) {
        push @lines, "- `$slug`: missing from the tenant"
          unless $copy->{$slug} || $NOT_COPIED{$slug};
    }
    return @lines;
}

# The Markdown report: a section per tenant schema, registry excluded.
sub report ($db) {
    my @tenants = $db->query(q{
        SELECT slug FROM registry.tenants WHERE slug <> 'registry' ORDER BY slug
    })->arrays->map( sub { $_->[0] } )->each;

    my $md = "# Tenant workflow divergence\n";
    for my $tenant (@tenants) {
        my @lines = _differences( $db, $tenant );
        $md .= "\n## $tenant\n\n" . ( @lines ? join( "\n", @lines ) : 'No differences.' ) . "\n";
    }
    return $md . "\n";
}

1;
