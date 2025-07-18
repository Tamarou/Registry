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
            "/usr/lib/postgresql/17/bin/pg_dump '$template_uri' > '$dump_file' 2>/dev/null",
            "/usr/lib/postgresql/16/bin/pg_dump '$template_uri' > '$dump_file' 2>/dev/null",
            "/usr/lib/postgresql/15/bin/pg_dump '$template_uri' > '$dump_file' 2>/dev/null",
            "/usr/lib/postgresql/14/bin/pg_dump '$template_uri' > '$dump_file' 2>/dev/null",
            "pg_dump '$template_uri' > '$dump_file' 2>/dev/null",
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
            "/usr/lib/postgresql/17/bin/psql '$uri' < '$dump_file' 2>/dev/null",
            "/usr/lib/postgresql/16/bin/psql '$uri' < '$dump_file' 2>/dev/null",
            "/usr/lib/postgresql/15/bin/psql '$uri' < '$dump_file' 2>/dev/null",
            "/usr/lib/postgresql/14/bin/psql '$uri' < '$dump_file' 2>/dev/null",
            "psql '$uri' < '$dump_file' 2>/dev/null",
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
        for my $change (@$changes) {
            App::Sqitch->new()->run('sqitch', 'deploy', '-t', $self->uri, $change);
        }
    }

    sub cleanup_test_database {
        my $self = shift;
        # Test::PostgreSQL automatically cleans up when the object is destroyed
        # Just make sure the connection is closed
        if ($self->{pgsql}) {
            undef $self->{pgsql};
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
}

1; # Return true value for module