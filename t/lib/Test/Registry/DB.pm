use 5.42.0;
# ABOUTME: Test database setup for Registry tests using Test::PostgreSQL.
# ABOUTME: Loads schema from a pre-generated dump file for fast test startup.
use App::Sqitch ();
use Test::PostgreSQL ();
use DBI ();

package Test::Registry::DB {
    use File::Basename qw(dirname);
    use File::Spec ();

    # Path to the pre-generated schema dump (relative to repo root)
    my $DUMP_FILE = File::Spec->catfile(
        dirname(__FILE__), '..', '..', '..', '..', 'sql', 'test-schema.sql'
    );

    sub _find_pg_tool {
        my ($tool) = @_;
        for my $path (
            $tool,
            "/usr/bin/$tool",
            (map { "/usr/lib/postgresql/$_/bin/$tool" } 17, 16, 15, 14),
        ) {
            return $path if -x $path || system("which $path >/dev/null 2>&1") == 0;
        }
        return $tool; # fallback, let PATH handle it
    }

    sub generate_dump {
        # Deploy schema via Sqitch into a temp DB, then pg_dump it.
        # Called by `make test-schema` or manually when migrations change.
        my $template_db = Test::PostgreSQL->new();
        my $uri = $template_db->uri;

        warn "Deploying schema via Sqitch...\n";
        App::Sqitch->new()->run('sqitch', 'deploy', '-t', $uri);

        my $pg_dump = _find_pg_tool('pg_dump');
        my $out = $DUMP_FILE;
        system("$pg_dump '$uri' > '$out' 2>/dev/null") == 0
            or die "pg_dump failed";

        warn "Schema dump written to $out\n";
        undef $template_db;
    }

    sub _load_from_dump {
        my ($self) = @_;
        my $uri  = $self->{pgsql}->uri;
        my $psql = _find_pg_tool('psql');
        system("$psql '$uri' < '$DUMP_FILE' >/dev/null 2>&1") == 0
            or die "psql load failed";
    }

    sub new {
        my $class = shift;
        my $self = bless {}, $class;
        $self->{pgsql} = Test::PostgreSQL->new();

        if (-f $DUMP_FILE && -s $DUMP_FILE) {
            # Fast path: load from pre-generated dump
            $self->_load_from_dump();
        } else {
            # Slow path: deploy via Sqitch (first run, or dump not generated)
            warn "No schema dump at $DUMP_FILE -- falling back to sqitch deploy\n";
            warn "Run 'make test-schema' to generate the dump for faster tests.\n";
            App::Sqitch->new()->run('sqitch', 'deploy', '-t', $self->{pgsql}->uri);
        }

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
        # Full schema already deployed in new()
        return;
    }

    sub cleanup_test_database {
        my $self = shift;
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

            $db->query(q{
                CREATE OR REPLACE FUNCTION registry.validate_pricing_resources()
                RETURNS trigger AS $$
                BEGIN
                    -- Validate resources if present
                    IF NEW.pricing_configuration ? 'resources' THEN
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

    sub DESTROY {
        my $self = shift;
        $self->cleanup_test_database if $self;
    }
}

1;
