use 5.40.0;
use lib          qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw( done_testing is like is_deeply)];
defer { done_testing };

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
description: Testing round trip serialization
steps:
  - slug: step-one
    description: A test step
    template: test-template
END_YAML

    # Create workflow from YAML
    my $workflow = Registry::DAO::Workflow->from_yaml( $dao->db, $input_yaml );

    # Now serialize it back
    my $output_yaml = $workflow->to_yaml( $dao->db );

    # Load both YAMLs for comparison
    my $input_data  = Load($input_yaml);
    my $output_data = Load($output_yaml);

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
