use 5.40.2;
use utf8;
use experimental qw(try);
use Object::Pad;

class Registry::DAO::UserPreference :isa(Registry::DAO::Object) {
    use Carp qw( croak );
    use JSON qw( decode_json encode_json );
    
    field $id :param :reader;
    field $user_id :param :reader;
    field $preference_key :param :reader;
    field $preference_value :param :reader = {};
    field $created_at :param :reader;
    field $updated_at :param :reader;
    
    use constant table => 'user_preferences';
    
    BUILD {
        # Ensure preference_value is a hash ref if it's a string
        if (defined $preference_value && !ref $preference_value) {
            try {
                $preference_value = decode_json($preference_value);
            }
            catch ($e) {
                croak "Invalid JSON in preference_value: $e";
            }
        }
        $preference_value //= {};
    }
    
    sub create ($class, $db, $data) {
        # Validate required fields
        for my $field (qw(user_id preference_key)) {
            croak "Missing required field: $field" unless $data->{$field};
        }
        
        # Ensure preference_value is JSON-serializable
        if (ref $data->{preference_value}) {
            $data->{preference_value} = encode_json($data->{preference_value});
        }
        
        $class->SUPER::create($db, $data);
    }
    
    # Get or create preference for user
    sub get_or_create ($class, $db, $user_id, $preference_key, $default_value = {}) {
        my $existing = $class->find($db, { 
            user_id => $user_id, 
            preference_key => $preference_key 
        });
        
        return $existing if $existing;
        
        return $class->create($db, {
            user_id => $user_id,
            preference_key => $preference_key,
            preference_value => $default_value
        });
    }
    
    # Get user's notification preferences
    sub get_notification_preferences ($class, $db, $user_id) {
        my $pref = $class->get_or_create($db, $user_id, 'notifications', {
            attendance_missing => { email => 1, in_app => 1 },
            attendance_reminder => { email => 1, in_app => 1 }
        });
        
        return $pref->preference_value;
    }
    
    # Update notification preferences
    sub update_notification_preferences ($class, $db, $user_id, $preferences) {
        my $pref = $class->get_or_create($db, $user_id, 'notifications');
        
        # Merge with existing preferences
        my $current = $pref->preference_value;
        my $updated = { %$current, %$preferences };
        
        $pref->update($db, { preference_value => $updated });
        return $pref;
    }
    
    # Check if user wants notifications for a specific type and channel
    sub wants_notification ($class, $db, $user_id, $notification_type, $channel = 'email') {
        my $prefs = $class->get_notification_preferences($db, $user_id);
        
        return $prefs->{$notification_type}{$channel} // 0;
    }
    
    # Get all preferences for a user
    sub get_user_preferences ($class, $db, $user_id) {
        my $results = $db->select(
            $class->table,
            undef,
            { user_id => $user_id },
            { -asc => 'preference_key' }
        )->hashes;
        
        my $preferences = {};
        for my $row (@$results) {
            my $value = $row->{preference_value};
            if (ref $value eq 'HASH' || ref $value eq 'ARRAY') {
                $preferences->{$row->{preference_key}} = $value;
            } else {
                try {
                    $preferences->{$row->{preference_key}} = decode_json($value);
                }
                catch ($e) {
                    $preferences->{$row->{preference_key}} = $value;
                }
            }
        }
        
        return $preferences;
    }
    
    # Set a specific preference value
    method set_value ($db, $new_value) {
        my $value_to_store = ref $new_value ? encode_json($new_value) : $new_value;
        $self->update($db, { preference_value => $value_to_store });
        $preference_value = $new_value;
    }
    
    # Get preference value with default
    method get_value ($default = undef) {
        return $preference_value // $default;
    }
    
    # Get nested preference value using dot notation (e.g., "notifications.email.enabled")
    method get_nested_value ($key_path, $default = undef) {
        my @keys = split /\./, $key_path;
        my $value = $preference_value;
        
        for my $key (@keys) {
            return $default unless ref $value eq 'HASH' && exists $value->{$key};
            $value = $value->{$key};
        }
        
        return $value // $default;
    }
    
    # Set nested preference value using dot notation
    method set_nested_value ($db, $key_path, $new_value) {
        my @keys = split /\./, $key_path;
        my $current = { %$preference_value }; # Deep copy
        
        # Navigate to the parent of the target key
        my $parent = $current;
        for my $i (0 .. $#keys - 1) {
            my $key = $keys[$i];
            $parent->{$key} = {} unless ref $parent->{$key} eq 'HASH';
            $parent = $parent->{$key};
        }
        
        # Set the final value
        $parent->{$keys[-1]} = $new_value;
        
        $self->set_value($db, $current);
    }
    
    # Get related objects
    method user ($db) {
        require Registry::DAO::User;
        Registry::DAO::User->find($db, { id => $user_id });
    }
    
    # Helper methods
    method is_notification_preference {
        return $preference_key eq 'notifications';
    }
    
    method has_preference ($key) {
        return exists $preference_value->{$key};
    }
}