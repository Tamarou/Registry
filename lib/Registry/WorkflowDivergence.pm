# ABOUTME: Read-only report of how each tenant's copy of the workflows differs from the platform's (registry schema).
# ABOUTME: Compares slugs, step order, step class and template by name and exact content; output is Markdown, one section per tenant.
use 5.42.0;
use experimental 'signatures';

package Registry::WorkflowDivergence;

use Digest::SHA qw( sha256_hex );
use Encode      qw( encode_utf8 );
use Mojo::File;
use Registry::DAO::Tenant;
use Registry::DAO::Workflow;

# Provisioning never copies these to a tenant, so their absence is expected.
my %NOT_COPIED = map { $_ => 1 } qw( tenant-signup registry-storefront );

# Is workflow $slug the platform's alone, never copied to a tenant? The one
# list provisioning and accepting the platform's offer both read.
sub never_copied ($slug) { $NOT_COPIED{$slug} ? 1 : 0 }

# Steps whose template provisioning unlinks in the tenant on purpose (refs #173
# #229): registry's is the platform's marketing page, and the tenant must fall
# back to the disk catalog. Only the tenant having no template is expected.
my %UNLINKED = ( 'tenant-storefront' => { 'program-listing' => 1 } );

# Every workflow in $schema (already quoted), by slug, each with its steps in
# walk order: first_step, then the depends_on chain (children by slug), then
# any step the chain does not reach, by slug.
sub _workflows ( $db, $schema ) {
    my %by_id = map { $_->{id} => { %$_, steps => [] } }
      Registry::DAO::Workflow->rows_in_schema( $db, $schema );

    my ( %steps, %children );
    for my $s ( Registry::DAO::Workflow->step_rows_in_schema( $db, $schema ) ) {
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

    # Who may run it is the gate's data, so part of what the workflow is.
    my @roles = map { _name( $_->{roles} && join ', ', sort $_->{roles}->@* ) } $platform, $copy;
    push @lines, "- `$slug`: roles: registry $roles[0]; tenant $roles[1]" if $roles[0] ne $roles[1];
    my @public = map { $_->{public} ? 'true' : 'false' } $platform, $copy;
    push @lines, "- `$slug`: public: registry `$public[0]`; tenant `$public[1]`" if $public[0] ne $public[1];

    my %mine = map { $_->{slug} => $_ } $copy->{steps}->@*;
    for my $p ( sort { $a->{slug} cmp $b->{slug} } $platform->{steps}->@* ) {
        my $c = $mine{ $p->{slug} } or next;
        my $unlinked = $UNLINKED{$slug}{ $p->{slug} } && !defined $c->{template};
        for ( [ class => 'class', \&_name ], [ template => 'template', \&_name ], [ content => 'template content', \&_content ] ) {
            my ( $field, $label, $show ) = @$_;
            next if $unlinked && $field ne 'class';
            next if ( $p->{$field} // "\0none" ) eq ( $c->{$field} // "\0none" );
            push @lines, sprintf "- `%s` step `%s`: %s: registry %s; tenant %s",
              $slug, $p->{slug}, $label, $show->( $p->{$field} ), $show->( $c->{$field} );
        }
    }
    return @lines;
}

sub _differences ( $db, $platform, $tenant ) {
    my $copy     = _workflows( $db, $db->dbh->quote_identifier($tenant) );

    my @lines;
    for my $slug ( sort keys %$copy ) {
        push @lines, "- `$slug`: only in the tenant" unless $platform->{$slug};
    }
    for my $slug ( sort keys %$platform ) {
        push @lines, "- `$slug`: missing from the tenant"
          unless $copy->{$slug} || $NOT_COPIED{$slug};
        push @lines, "- `$slug`: the tenant holds a copy; provisioning never copies it"
          if $copy->{$slug} && $NOT_COPIED{$slug};
        push @lines, _compare( $slug, $platform->{$slug}, $copy->{$slug} ) if $copy->{$slug};
    }
    return @lines;
}

# How $tenant's copy of workflow $slug differs from registry's, as the
# report's lines for it: none when they are the same.
sub differences_for ( $db, $tenant, $slug ) {
    my ( $platform, $copy ) = map { _workflows( $db, $_ )->{$slug} } 'registry', $db->dbh->quote_identifier($tenant);
    return _compare( $slug, $platform, $copy );
}

# perigrin's rulings, as { "<tenant>/<slug>" => 'replace' | 'merge' }, from the
# `Ruling: replace <tenant>/<slug>` and `Ruling: merge <tenant>/<slug>` lines of
# $text, by default the recorded report. Any other line rules nothing.
sub rulings ( $text = Mojo::File::curfile->dirname->dirname->dirname
                          ->child(qw( docs reviews tenant-workflow-divergence.md ))->slurp ) {
    my %ruled;
    $ruled{"$2/$3"} = $1 while $text =~ m{^Ruling: (replace|merge) ([^\s/]+)/(\S+)[ \t]*$}mg;
    return \%ruled;
}

# The Markdown report: a section per tenant schema, registry excluded.
sub report ($db) {
    my @tenants = Registry::DAO::Tenant->slugs_with_schema_presence($db);

    my $platform = _workflows( $db, 'registry' );
    my $md       = "# Tenant workflow divergence\n";
    for my $row (@tenants) {
        my $tenant = $row->{slug};
        my @lines  = ("- error: schema `$tenant` does not exist");
        if ( $row->{present} ) {
            # One broken tenant is a line in the report, not the end of it.
            @lines = eval { _differences( $db, $platform, $tenant ) };
            if ( my $err = $@ ) { $err =~ s/\s+/ /g; @lines = ("- error: $err") }
        }
        $md .= "\n## $tenant\n\n" . ( @lines ? join( "\n", @lines ) : 'No differences.' ) . "\n";
    }
    return $md . "\n";
}

1;
