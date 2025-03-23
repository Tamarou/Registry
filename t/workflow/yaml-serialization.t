use 5.40.0;
use lib          qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw( done_testing is like is_deeply fail note)];
defer { done_testing };

use Mojo::Home;
use Registry::DAO;
use Test::Registry::DB;
use YAML::XS;

my $dao = Registry::DAO->new( url => Test::Registry::DB->new_test_db() );

{
    # basic yaml serialization
    my $workflow = $dao->create(
        Workflow => {
            slug        => 'test',
            name        => 'Test Workflow',
            description => 'A test workflow',
        }
    );

    my $template = $dao->create(
        Template => {
            name    => 'Test Template',
            slug    => 'test-template',
            content => '<form>Test content</form>',
        }
    );

    $workflow->add_step(
        $dao,
        {
            slug        => 'step-one',
            template_id => $template->id,
            description => 'A test step',
        }
    );

    my $yaml = $workflow->to_yaml($dao);
    my $data = Load($yaml);

    is $data->{name}, 'Test Workflow', 'workflow name serialized correctly';
    is $data->{description}, 'A test workflow',
      'description serialized correctly';

    is $data->{steps}[0]{slug}, 'step-one', 'step slug serialized correctly';
    is $data->{steps}[0]{template}, $template->slug,
      'template serialized correctly';
}

{    # round trip serialization
    my $input_yaml = <<'END_YAML';
name: Round Trip Test
slug: round-trip-test
description: Testing round trip serialization
steps:
  - slug: step-one
    description: A test step
    template: test-template
    class: Registry::DAO::WorkflowStep
END_YAML

    # Create workflow from YAML
    my $workflow = Registry::DAO::Workflow->from_yaml( $dao, $input_yaml );

    # Now serialize it back
    my $output_yaml = $workflow->to_yaml( $dao->db );

    # Load both YAMLs for comparison
    my $input_data  = Load($input_yaml);
    my $output_data = Load($output_yaml);
    
    # If first_step is missing from original but present in output, remove it for comparison
    if (!exists $input_data->{first_step} && exists $output_data->{first_step}) {
        delete $output_data->{first_step};
    }

    is_deeply $output_data, $input_data, 'round trip preserves YAML structure';

    # Verify database relationships were created correctly
    is $workflow->first_step( $dao->db )->template( $dao->db )->slug,
      'test-template', 'template association created correctly';
}

{    # error handling
    eval { Registry::DAO::Workflow->from_yaml( $dao->db, "invalid: yaml: [" ) };
    like $@, qr/YAML::XS::Load Error:/, 'invalid YAML throws error';

    eval { Registry::DAO::Workflow->from_yaml( $dao->db, "name: Test\n" ) };
    like $@, qr/Missing required field/, 'missing required fields throws error';
}

{
    # Import templates
    my @templates =
      Mojo::Home->new->child('templates')->list_tree->grep(qr/\.html\.ep$/)
      ->each;

    for (@templates) {
        Registry::DAO::Template->import_from_file( $dao, $_ );
    }

    # Import schemas/outcome definitions
    my @schemas =
      Mojo::Home->new->child('schemas')->list->grep(qr/\.json$/)->each;

    for my $file (@schemas) {
        try {
            my $outcome = Registry::DAO::OutcomeDefinition->import_from_file( $dao, $file );
            note "Imported schema " . $outcome->name if $outcome;
            
            # Verify the schema is in the database
            my ($check) = Registry::DAO::OutcomeDefinition->find($dao->db, { name => $outcome->name });
            if ($check) {
                note "Verified schema '" . $check->name . "' in database with ID " . $check->id;
            } else {
                warn "Failed to find schema '" . $outcome->name . "' in database after import";
            }
        }
        catch ($e) {
            warn "Error importing schema: $e";
        }
    }

    my @files =
      Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each;
    for my $file (@files) {
        my $yaml = $file->slurp;
        if ( Load($yaml)->{draft} ) {
            note "Skipping draft workflow $file";
            next;
        }
        try {
            # Check outcome definitions in the YAML if any
            my $data = Load($yaml);
            for my $step (@{$data->{steps} || []}) {
                if (my $outcome_name = $step->{'outcome-definition'}) {
                    my ($check) = Registry::DAO::OutcomeDefinition->find($dao->db, { name => $outcome_name });
                    if ($check) {
                        note "Found outcome definition for step: $outcome_name (ID: " . $check->id . ")";
                    } else {
                        warn "YAML references outcome definition '$outcome_name' but it's not in the database";
                    }
                }
            }
            
            my $workflow = Registry::DAO::Workflow->from_yaml( $dao, $yaml );
            # Special handling for class field - we need to handle cases where original YAML doesn't have it
            my $original = Load($yaml);
            my $from_db = Load($workflow->to_yaml($dao));
            
            # If class is missing from original but present in from_db, remove it for comparison
            for my $i (0..$#{$original->{steps} || []}) {
            if (!exists $original->{steps}[$i]{class} && exists $from_db->{steps}[$i]{class}) {
            delete $from_db->{steps}[$i]{class};
            }
            }
    
    # If first_step is missing from original but present in from_db, remove it for comparison
    if (!exists $original->{first_step} && exists $from_db->{first_step}) {
        delete $from_db->{first_step};
    }
            
            is_deeply $from_db, $original, "able to round trip $file";
        }
        catch ($e) {
            fail "Unable to round trip $file: $e";
        }
    }
}
