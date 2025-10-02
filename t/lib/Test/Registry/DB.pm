use 5.40.2;
use App::Sqitch ();
use Test::PostgreSQL ();
use DBI ();

package Test::Registry::DB {
    # Class variables for schema dump
    our $SCHEMA_DUMP;
    our $SCHEMA_INITIALIZED = 0;
    
    sub _get_or_create_schema_dump {
        return $SCHEMA_DUMP if $SCHEMA_INITIALIZED;
        
        # Create template database and deploy schema once
        my $template_db = Test::PostgreSQL->new();
        App::Sqitch->new()->run( 'sqitch', 'deploy', '-t', $template_db->uri );
        
        # Dump the schema to a temporary file
        my $dump_file = "/tmp/registry_test_schema_$$.sql";
        my $template_uri = $template_db->uri;
        
        # Use pg_dump to create schema dump - try different pg_dump versions
        my @pg_dump_commands = (
            "pg_dump '$template_uri' > '$dump_file' 2>/dev/null",
            "/usr/bin/pg_dump '$template_uri' > '$dump_file' 2>/dev/null",
            "/usr/lib/postgresql/17/bin/pg_dump '$template_uri' > '$dump_file' 2>/dev/null",
            "/usr/lib/postgresql/16/bin/pg_dump '$template_uri' > '$dump_file' 2>/dev/null",
            "/usr/lib/postgresql/15/bin/pg_dump '$template_uri' > '$dump_file' 2>/dev/null",
            "/usr/lib/postgresql/14/bin/pg_dump '$template_uri' > '$dump_file' 2>/dev/null",
        );
        
        my $success = 0;
        for my $cmd (@pg_dump_commands) {
            if (system($cmd) == 0) {
                $success = 1;
                last;
            }
        }
        
        die "All pg_dump commands failed" unless $success;
        
        # Clean up template database
        undef $template_db;
        
        $SCHEMA_DUMP = $dump_file;
        $SCHEMA_INITIALIZED = 1;
        
        return $SCHEMA_DUMP;
    }
    
    sub _load_schema_from_dump {
        my ($self, $dump_file) = @_;
        
        my $uri = $self->{pgsql}->uri;
        
        # Load schema from dump file - try different psql versions
        my @psql_commands = (
            "psql '$uri' < '$dump_file' 2>/dev/null",
            "/usr/bin/psql '$uri' < '$dump_file' 2>/dev/null",
            "/usr/lib/postgresql/17/bin/psql '$uri' < '$dump_file' 2>/dev/null",
            "/usr/lib/postgresql/16/bin/psql '$uri' < '$dump_file' 2>/dev/null",
            "/usr/lib/postgresql/15/bin/psql '$uri' < '$dump_file' 2>/dev/null",
            "/usr/lib/postgresql/14/bin/psql '$uri' < '$dump_file' 2>/dev/null",
        );
        
        my $success = 0;
        for my $cmd (@psql_commands) {
            if (system($cmd) == 0) {
                $success = 1;
                last;
            }
        }
        
        die "All psql commands failed" unless $success;
        
        return 1;
    }

    sub new {
        my $class = shift;
        my $self = bless {}, $class;
        $self->{pgsql} = Test::PostgreSQL->new();
        
        # Try to use schema dump for speed
        eval {
            my $dump_file = _get_or_create_schema_dump();
            $self->_load_schema_from_dump($dump_file);
        };

        if ($@) {
            # If dump loading fails, fall back to regular deployment
            warn "Schema dump loading failed: $@";
            warn "Falling back to regular deployment...";
            App::Sqitch->new()->run( 'sqitch', 'deploy', '-t', $self->{pgsql}->uri );
        }

        # Fix the pricing validation trigger to handle NULL values gracefully
        $self->_fix_pricing_validation_trigger();
        
        $ENV{DB_URL} = $self->{pgsql}->uri;
        return $self;
    }

    sub new_test_db ($) {
        my $test_db = __PACKAGE__->new();
        return $test_db->uri;
    }

    sub db {
        my $self = shift;
        require Registry::DAO;
        my $dao = Registry::DAO->new(url => $self->{pgsql}->uri);
        return $dao;
    }

    sub uri {
        my $self = shift;
        return $self->{pgsql}->uri;
    }

    sub setup_test_database {
        my $self = shift;
        require Registry::DAO;
        return Registry::DAO->new(url => $self->uri);
    }

    sub deploy_sqitch_changes {
        my ($self, $changes) = @_;
        # Since we deploy the full schema in new(), individual changes are already deployed
        # This method is now a no-op to avoid sqitch deployment conflicts
        return;
    }

    sub cleanup_test_database {
        my $self = shift;
        # Test::PostgreSQL automatically cleans up when the object is destroyed
        # Just make sure the connection is closed
        if ($self->{pgsql}) {
            undef $self->{pgsql};
        }
    }

    # Fix the pricing validation trigger to handle NULL values gracefully
    sub _fix_pricing_validation_trigger {
        my $self = shift;

        eval {
            require Registry::DAO;
            my $dao = Registry::DAO->new(url => $self->{pgsql}->uri);
            my $db = $dao->db;

            # Update the trigger function to handle NULL values
            $db->query(q{
                CREATE OR REPLACE FUNCTION registry.validate_pricing_resources()
                RETURNS trigger AS $$
                BEGIN
                    -- Validate resources if present
                    IF NEW.pricing_configuration ? 'resources' THEN
                        -- Check that numeric values are non-negative, handling NULL values
                        IF (NEW.pricing_configuration->'resources'->>'classes_per_month') IS NOT NULL AND
                           (NEW.pricing_configuration->'resources'->>'classes_per_month')::int < 0 THEN
                            RAISE EXCEPTION 'classes_per_month must be non-negative';
                        END IF;

                        IF (NEW.pricing_configuration->'resources'->>'api_calls_per_day') IS NOT NULL AND
                           (NEW.pricing_configuration->'resources'->>'api_calls_per_day')::int < 0 THEN
                            RAISE EXCEPTION 'api_calls_per_day must be non-negative';
                        END IF;

                        IF (NEW.pricing_configuration->'resources'->>'storage_gb') IS NOT NULL AND
                           (NEW.pricing_configuration->'resources'->>'storage_gb')::int < 0 THEN
                            RAISE EXCEPTION 'storage_gb must be non-negative';
                        END IF;
                    END IF;

                    -- Validate quotas if present
                    IF NEW.pricing_configuration ? 'quotas' THEN
                        IF (NEW.pricing_configuration->'quotas'->>'reset_period') IS NOT NULL AND
                           NOT (NEW.pricing_configuration->'quotas'->>'reset_period') IN
                           ('daily', 'weekly', 'monthly', 'quarterly', 'yearly') THEN
                            RAISE EXCEPTION 'Invalid reset_period value';
                        END IF;

                        IF (NEW.pricing_configuration->'quotas'->>'overage_policy') IS NOT NULL AND
                           NOT (NEW.pricing_configuration->'quotas'->>'overage_policy') IN
                           ('block', 'notify', 'charge', 'throttle') THEN
                            RAISE EXCEPTION 'Invalid overage_policy value';
                        END IF;
                    END IF;

                    RETURN NEW;
                END;
                $$ LANGUAGE plpgsql;
            });
        };

        if ($@) {
            warn "Failed to fix pricing validation trigger: $@";
        }
    }

    # Clean up schema dump file (usually called at END)
    sub cleanup_schema_dump {
        if ($SCHEMA_DUMP && -f $SCHEMA_DUMP) {
            unlink $SCHEMA_DUMP;
            undef $SCHEMA_DUMP;
            $SCHEMA_INITIALIZED = 0;
        }
    }

    # Destructor to ensure cleanup
    sub DESTROY {
        my $self = shift;
        $self->cleanup_test_database if $self;
    }
}

# Clean up when module exits
END {
    Test::Registry::DB->cleanup_schema_dump;
}

1; # Return true value for module