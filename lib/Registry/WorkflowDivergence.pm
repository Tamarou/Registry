# ABOUTME: Read-only report of how each tenant's copy of the workflows differs from the platform's (registry schema).
# ABOUTME: Compares slugs, step order, step class and template by name and exact content; output is Markdown, one section per tenant.
use 5.42.0;
use experimental 'signatures';

package Registry::WorkflowDivergence;

use Digest::SHA qw( sha256_hex );
use Encode      qw( encode_utf8 );

# Provisioning never copies these to a tenant, so their absence is expected.
my %NOT_COPIED = map { $_ => 1 } qw( tenant-signup registry-storefront );

# Every workflow in $schema (already quoted), by slug, each with its steps in
# walk order: first_step, then the depends_on chain (children by slug), then
# any step the chain does not reach, by slug.
sub _workflows ( $db, $schema ) {
    my %by_id = map { $_->{id} => { %$_, steps => [] } }
      $db->query("SELECT id, slug, first_step FROM $schema.workflows")->hashes->each;

    my ( %steps, %children );
    for my $s ( $db->query( qq{
        SELECT s.id, s.workflow_id, s.slug, s.depends_on, s.class,
               t.name AS template, t.content
          FROM $schema.workflow_steps s
          LEFT JOIN $schema.templates t ON t.id = s.template_id
         ORDER BY s.slug
    } )->hashes->each ) {
        push $steps{ $s->{workflow_id} }->@*, $s;
        push $children{ $s->{depends_on} }->@*, $s if $s->{depends_on};
    }

    for my $wf ( values %by_id ) {
        my %seen;
        my @todo = grep { $_->{slug} eq ( $wf->{first_step} // '' ) } ( $steps{ $wf->{id} } // [] )->@*;
        while ( my $s = shift @todo ) {
            next if $seen{ $s->{id} }++;    # a looping chain ends here
            push $wf->{steps}->@*, $s;
            unshift @todo, ( $children{ $s->{id} } // [] )->@*;
        }
        push $wf->{steps}->@*, grep { !$seen{ $_->{id} } } ( $steps{ $wf->{id} } // [] )->@*;
    }
    return { map { $_->{slug} => $_ } values %by_id };
}

sub _name ($v) { defined $v ? "`$v`" : '(none)' }

sub _content ($v) {
    return '(none)' unless defined $v;
    my $bytes = encode_utf8($v);
    return sprintf 'sha256 `%s` (%d bytes)', substr( sha256_hex($bytes), 0, 12 ), length $bytes;
}

# How workflow $slug's copy differs from the platform's, one line per field.
sub _compare ( $slug, $platform, $copy ) {
    my @lines;
    my @order = map { join ', ', map { $_->{slug} } $_->{steps}->@* } $platform, $copy;
    push @lines, "- `$slug`: steps: registry `$order[0]`; tenant `$order[1]`"
      if $order[0] ne $order[1];

    my %mine = map { $_->{slug} => $_ } $copy->{steps}->@*;
    for my $p ( sort { $a->{slug} cmp $b->{slug} } $platform->{steps}->@* ) {
        my $c = $mine{ $p->{slug} } or next;
        for ( [ class => 'class', \&_name ], [ template => 'template', \&_name ], [ content => 'template content', \&_content ] ) {
            my ( $field, $label, $show ) = @$_;
            next if ( $p->{$field} // "\0none" ) eq ( $c->{$field} // "\0none" );
            push @lines, sprintf "- `%s` step `%s`: %s: registry %s; tenant %s",
              $slug, $p->{slug}, $label, $show->( $p->{$field} ), $show->( $c->{$field} );
        }
    }
    return @lines;
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
        push @lines, _compare( $slug, $platform->{$slug}, $copy->{$slug} ) if $copy->{$slug};
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
