#!/usr/bin/env perl
# ABOUTME: The offer-publishing step classes never branch on a plan or offer name, plan type, the platform slug or the all-zeros id.
# ABOUTME: Any tenant, the platform included, gets the same workflow; the scanner self-tests so it cannot pass vacuously.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use YAML::XS ();

my %FORBIDDEN = (
    'registry slug comparison' => qr/(?:\b(?:eq|ne)|[!=]=)\s*['"]registry['"]|['"]registry['"]\s*(?:\b(?:eq|ne)\b|[!=]=)/,
    'all-zeros id'             => qr/00000000-0000-0000-0000-000000000000/,
    'plan type or scope'       => qr/\bplan_(?:type|scope)\b/,
    'name comparison'          => qr/name\b[)}\s]*(?:\b(?:eq|ne)\b|[!=]=|=~|!~)\s*['"]|['"]\s*(?:\b(?:eq|ne)\b|[!=]=)\s*\S*name\b|\bname\s*=\s*'/,
);

# "<label>: <pattern name>: <line>" for every forbidden pattern in each source.
sub scan (%sources) {
    my @hits;
    for my $label ( sort keys %sources ) {
        for my $line ( split /\n/, $sources{$label} ) {
            push @hits, map { "$label: $_: $line" } grep { $line =~ $FORBIDDEN{$_} } sort keys %FORBIDDEN;
        }
    }
    return @hits;
}

# Scans @files; dies on an empty list or a missing file, so it never passes
# for having read nothing.
sub scan_files (@files) {
    die "no step class files to scan\n" unless @files;
    my %sources;
    for my $file (@files) {
        open my $fh, '<', $file or die "cannot read step class file $file: $!\n";
        local $/;
        $sources{$file} = <$fh>;
    }
    return scan(%sources);
}

# The workflow's own step classes, less the generic base step.
my $workflow = YAML::XS::LoadFile('workflows/offer-publishing.yml');
my @files    = map { ( my $f = "lib/$_.pm" ) =~ s{::}{/}g; $f }
    grep { $_ ne 'Registry::DAO::WorkflowStep' } map { $_->{class} } $workflow->{steps}->@*;

subtest 'offer step classes name no plan or tenant' => sub {
    cmp_ok scalar @files, '>=', 10, 'every offer-publishing step class is scanned';
    my @hits = scan_files(@files);
    is_deeply \@hits, [], 'no step class branches on a plan, tenant or name' or diag join "\n", @hits;
};

subtest 'scanner flags synthetic forbidden patterns' => sub {
    for my $source (
        q{return if $slug eq 'registry';},
        q{return if 'registry' ne $tenant;},
        q{my $root = '00000000-0000-0000-0000-000000000000';},
        q{return if $plan->plan_type;},
        q{WHERE plan_scope = 'tenant'},
        q{return if $offer->name eq 'Solo';},
        q{return if $basic->{offer_name} ne "Solo";},
        q{return if 'Solo' eq $offer->name;},
        q{SELECT 1 FROM offers WHERE name = 'Solo'},
    ) {
        ok scalar scan( synthetic => $source ), "flags: $source";
    }
    ok !scan( synthetic => q{Registry::DAO::Offer->create( $db, { name => $basic->{offer_name} } )} ),
        'passes a name that is only stored';
    ok !eval { scan_files(); 1 }, 'an empty class list fails';
    like $@, qr/no step class files/, 'saying so';
    ok !eval { scan_files('lib/Registry/DAO/WorkflowSteps/NoSuchStep.pm'); 1 }, 'a missing class file fails';
    like $@, qr/cannot read step class file/, 'saying so';
};

done_testing;
