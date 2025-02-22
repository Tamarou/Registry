use 5.40.0;
use lib          qw(lib t/lib);
use experimental qw(defer builtin);

use Test::More import => [qw(done_testing is is_deeply like ok)];
use Test::Exception;

defer { done_testing };

use Registry::DAO;
use Test::Registry::DB;

my $dao = Registry::DAO->new( url => Test::Registry::DB->new_test_db() );

{
    # Test basic location creation
    my $location = $dao->create(
        'Location' => {
            name => 'Test Location',
            slug => 'test-location'
        }
    );

    ok $location->id, 'Location created with ID';
    is $location->name, 'Test Location', 'Name saved correctly';
    is $location->slug, 'test-location', 'Slug saved correctly';
    is_deeply $location->address_info, {},
      'Empty address_info defaults to empty hashref';
}

{
    # Test full address data
    my $full_location = $dao->create(
        'Location' => {
            name         => 'Full Address Location',
            slug         => 'full-address',
            address_info => {
                street_address => '123 Main St',
                unit           => 'Suite 456',
                city           => 'Portland',
                state          => 'OR',
                postal_code    => '97201',
                country        => 'USA',
                coordinates    => {
                    lat => 45.5155,
                    lng => -122.6789
                }
            }
        }
    );

    ok $full_location->id, 'Full location created with ID';
    is $full_location->address_info->{street_address}, '123 Main St',
      'Street address saved';
    is $full_location->address_info->{city}, 'Portland', 'City saved';
    ok $full_location->has_coordinates, 'Has coordinates';

    my ( $lat, $lng ) = $full_location->get_coordinates;
    is $lat,  45.5155,  'Latitude retrieved correctly';
    is $lng, -122.6789, 'Longitude retrieved correctly';

    like $full_location->get_formatted_address,
      qr/123 Main St.*Suite 456.*Portland, OR, 97201.*USA/s,
      'Address formats correctly';
}
__END__
{
    # Test coordinate validation
    throws_ok {
        $dao->create('Location' => {
            name => 'Bad Coords',
            slug => 'bad-coords',
            address_info => {
                coordinates => {
                    lat => 91,  # Invalid latitude
                    lng => 0
                }
            }
        });
    } qr/Invalid latitude/, 'Catches invalid latitude';

    throws_ok {
        $dao->create('Location' => {
            name => 'Bad Coords 2',
            slug => 'bad-coords-2',
            address_info => {
                coordinates => {
                    lat => 0,
                    lng => 181  # Invalid longitude
                }
            }
        });
    } qr/Invalid longitude/, 'Catches invalid longitude';
}

{
    # Test address_info validation
    throws_ok {
        $dao->create('Location' => {
            name => 'Bad Address',
            slug => 'bad-address',
            address_info => []  # Invalid - not a hashref
        });
    } qr/address_info must be a hashref/, 'Catches invalid address_info structure';
}

{
    # Test serialization
    my $location = $dao->create('Location' => {
        name => 'JSON Test',
        slug => 'json-test',
        address_info => {
            street_address => '789 Oak St',
            city => 'Portland',
            state => 'OR'
        }
    });

    my $json = $location->TO_JSON;
    ok $json->{id}, 'JSON includes ID';
    is $json->{name}, 'JSON Test', 'JSON includes name';
    is $json->{address_info}{street_address}, '789 Oak St', 'JSON includes address_info';
}

{
    # Test read-back and update
    my ($found) = $dao->find('Location' => { slug => 'json-test' });
    ok $found, 'Found location by slug';
    is $found->name, 'JSON Test', 'Found correct location';
    is $found->address_info->{city}, 'Portland', 'Address info preserved in database';
}
