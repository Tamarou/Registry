use 5.40.2;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test2::V0;
defer { done_testing };

use Test::Mojo;
use Registry::DAO;
use Test::Registry::DB;
use Mojo::File qw(path tempdir curfile);
use Mojo::JSON qw(encode_json decode_json);

# Create a test database
my $dao = Registry::DAO->new(url => Test::Registry::DB->new_test_db());
$ENV{DB_URL} = $dao->url;

# Test basic outcome definition creation
subtest 'Create outcome definition' => sub {
    my $data = {
        name => 'Test Outcome',
        description => 'A test outcome definition',
        schema => {
            name => 'Test Outcome',
            description => 'A test outcome definition',
            fields => [
                {
                    id => 'testField',
                    type => 'text',
                    label => 'Test Field',
                    required => \1
                }
            ]
        }
    };
    
    my $outcome = Registry::DAO::OutcomeDefinition->create($dao->db, $data);
    ok($outcome, 'Created outcome definition');
    is($outcome->name, 'Test Outcome', 'Name set correctly');
    is($outcome->description, 'A test outcome definition', 'Description set correctly');
    is(ref $outcome->schema, 'HASH', 'Schema parsed as a hash');
    is($outcome->schema->{name}, 'Test Outcome', 'Schema name set correctly');
    is(scalar @{$outcome->schema->{fields}}, 1, 'One field defined');
};

# Test import from file
subtest 'Import from file' => sub {
    # Create a temporary JSON file
    my $fixtures_dir = curfile->dirname->sibling('fixtures')->child('schemas');
    $fixtures_dir->make_path unless -d $fixtures_dir;
    my $file = $fixtures_dir->child('test-schema.json');
    
    $file->spew(encode_json({
        name => 'Imported Outcome',
        description => 'An imported outcome definition',
        fields => [
            {
                id => 'importedField',
                type => 'text',
                label => 'Imported Field',
                required => \1
            }
        ]
    }));
    
    my $outcome = Registry::DAO::OutcomeDefinition->import_from_file($dao->db, $file);
    ok($outcome, 'Imported outcome definition');
    is($outcome->name, 'Imported Outcome', 'Name set correctly');
    is($outcome->description, 'An imported outcome definition', 'Description set correctly');
    is(ref $outcome->schema, 'HASH', 'Schema parsed as a hash');
    is($outcome->schema->{name}, 'Imported Outcome', 'Schema name set correctly');
    is(scalar @{$outcome->schema->{fields}}, 1, 'One field defined');
    
    # Test updating existing definition
    $file->spew(encode_json({
        name => 'Imported Outcome',
        description => 'Updated description',
        fields => [
            {
                id => 'importedField',
                type => 'text',
                label => 'Imported Field',
                required => \1
            },
            {
                id => 'secondField',
                type => 'number',
                label => 'Second Field',
                required => \0
            }
        ]
    }));
    
    my $updated = Registry::DAO::OutcomeDefinition->import_from_file($dao->db, $file);
    ok($updated, 'Updated outcome definition');
    is($updated->id, $outcome->id, 'Same ID as original');
    is($updated->description, 'Updated description', 'Description updated');
    is(scalar @{$updated->schema->{fields}}, 2, 'Two fields defined');
};

# Test Registry import_schemas method
subtest 'Registry import_schemas' => sub {
    my $app = Test::Mojo->new('Registry')->app;
    
    # Add temporary schema files to the app's home/schemas directory
    my $schemas_dir = path($app->home, 'schemas');
    $schemas_dir->make_path unless -d $schemas_dir;
    
    my $test_schema = $schemas_dir->child('test-outcome.json');
    $test_schema->spew(encode_json({
        name => 'App Schema',
        description => 'A schema imported by the app',
        fields => [
            {
                id => 'appField',
                type => 'text',
                label => 'App Field',
                required => \1
            }
        ]
    }));
    
    # Run the import
    $app->import_schemas();
    
    # Verify the schema was imported
    my ($outcome) = Registry::DAO::OutcomeDefinition->find($app->dao->db, { name => 'App Schema' });
    ok($outcome, 'Schema was imported');
    is($outcome->description, 'A schema imported by the app', 'Description matches');
    is(scalar @{$outcome->schema->{fields}}, 1, 'One field defined');
    
    # Clean up
    $test_schema->remove;
};