use 5.40.2;
use Mojo::JSON qw(decode_json encode_json);
use IO::Prompt;

sub prompt_from_schema {
    my ($schema) = @_;
    my %results;

    print $schema->{name},        "\n";
    print $schema->{description}, "\n" if $schema->{description};

    for my $field ( @{ $schema->{fields} } ) {
        my $prompt = $field->{label};
        $prompt .= " (required)" if $field->{required};

        if ( $field->{type} eq 'select' ) {

            # For select fields, create a list of options
            my $options = [ map { $_->{label} } @{ $field->{options} } ];
            use DDP;
            p $options;
            my $choice = prompt(
                "$prompt: ",
                -menu    => $options,
                -default => $$options[0]
            );

            # Map the label back to value
            for my $opt ( @{ $field->{options} } ) {
                if ( $opt->{label} eq $choice ) {
                    $results{ $field->{id} } = $opt->{value};
                    last;
                }
            }
        }
        elsif ( $field->{type} eq 'textarea' ) {
            $results{ $field->{id} } = prompt( "$prompt: ", -default => '' );
        }
        else {
            my %prompt_args = (
                -prompt  => "$prompt: ",
                -default => '',
            );

            $results{ $field->{id} } = prompt(%prompt_args);
        }
    }

    return \%results;
}

# Example usage:
use Mojo::Home;

my $home = Mojo::Home->new->detect;

my $schema_json = $home->child( 'schemas', 'meta-schema.json' )->slurp;
use DDP;
my $schema = decode_json($schema_json);
p $schema;
my $results = prompt_from_schema($schema);
print "Results:\n", encode_json($results), "\n";
