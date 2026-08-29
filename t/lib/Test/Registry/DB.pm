use 5.42.0;
# ABOUTME: Test database setup for Registry tests using Test::PostgreSQL.
# ABOUTME: Loads schema from a pre-generated dump file for fast test startup.
use App::Sqitch ();
use Test::PostgreSQL ();
use DBI ();

package Test::Registry::DB {
    use File::Basename qw(dirname);
    use File::Spec ();
    use Scalar::Util ();

    # Path to the pre-generated schema dump (relative to repo root)
    my $DUMP_FILE = File::Spec->catfile(
        dirname(__FILE__), '..', '..', '..', '..', 'sql', 'test-schema.sql'
    );

    # Live instances, tracked weakly so the END block below can stop their
    # ephemeral postgres servers deterministically -- before global
    # destruction -- and keep teardown noise out of the process exit code.
    my @LIVE_INSTANCES;

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

    # The lines a portable dump must not carry. Shared, because the comparison
    # in t/database/schema-dump-current.t has to filter identically or its two
    # sides differ for reasons that are not drift.
    #
    # transaction_timeout arrived in PostgreSQL 17, so 14, 15 and 16 reject it.
    # \restrict / \unrestrict are psql meta-commands from the Aug-2025 minors;
    # an older client calls them invalid, which ON_ERROR_STOP turns into an
    # abort before any DDL runs.
    #
    # Anchored at column 0. pg_dump writes these unindented, while plpgsql
    # bodies contain indented text that merely looks similar -- and stripping
    # THAT corrupts the artefact silently, because it lives inside string
    # literals the server never parses at load time.
    sub is_nonportable_line ($line) {
        return $line =~ /\ASET\s+transaction_timeout\s*=/
            || $line =~ /\A\\(un)?restrict\b/;
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

        # Strip pg_dump's preamble SETs on the way out, so the committed
        # artefact loads on every major we support rather than only on whichever
        # one generated it. They are session settings that cannot affect the
        # resulting schema, and they are the one part of a dump that is not
        # portable: 17 and 18 emit `SET transaction_timeout = 0`, which 14, 15
        # and 16 reject as an unrecognized parameter. Measured, that line is the
        # ONLY statement in this dump that fails to load on 14 -- every piece of
        # DDL is accepted -- but psql exits 0 through errors unless told
        # otherwise, so the failure was invisible for as long as nobody looked.
        # Filtering here rather than at each reader is what lets both loaders
        # run with ON_ERROR_STOP and mean it.
        # Dumped and filtered in two steps, because a shell pipeline reports
        # only its LAST command's status: `pg_dump | grep > out` returns grep's
        # 0 even when pg_dump died partway, which would commit a truncated
        # sql/test-schema.sql without a word. Measured -- `(emit a line; exit 3)
        # | grep -v ...` gives rc=0. That is the exact failure the rest of this
        # work exists to make impossible, so it does not get to hide in the
        # generator.
        my $raw = "$out.raw";
        system("$pg_dump '$uri' > '$raw'") == 0 or die "pg_dump failed";

        open my $in,  '<', $raw  or die "open $raw: $!";
        open my $dst, '>', $out  or die "open $out: $!";
        # print and close are checked too. A write that fails partway -- a full
        # disk is the ordinary case -- would otherwise ship a truncated
        # sql/test-schema.sql, announce success, and unlink the only complete
        # copy. The pipeline this replaced caught that; losing it while fixing
        # the other half would have been a poor trade.
        while ( my $line = <$in> ) {
            # pg_dump's preamble SETs are the one part of a dump that is not
            # portable across majors: 17 and 18 emit `SET transaction_timeout`,
            # which 14, 15 and 16 reject outright. Dropping them lets every
            # reader load this file with ON_ERROR_STOP and mean it. The rest are
            # server defaults on any database we load into, so re-establishing
            # them is not the artefact's job.
            # By NAME, at column 0, and only the ones that are not portable.
            #
            # Column 0 because plpgsql bodies contain INDENTED `SET` --
            # registry.copy_workflow has two, inside a dynamic EXECUTE string.
            # Stripping those leaves CREATE FUNCTION succeeding (they are inside
            # a string literal), so the artefact loads clean and tenant cloning
            # then dies on `UPDATE ... WHERE` with no SET clause.
            #
            # By name because the rest of pg_dump's preamble is not decoration.
            # check_function_bodies = false is why a dump whose functions are
            # written before its tables loads at all; client_min_messages =
            # warning is what keeps NOTICE off stderr and out of TAP. Dropping
            # the whole preamble to solve one incompatible line traded a known
            # problem for two latent ones.
            #
            # transaction_timeout arrived in PostgreSQL 17, so a dump written on
            # 17 or 18 is rejected outright by 14, 15 and 16. If a later release
            # adds another, this load fails loudly naming it -- which is the
            # right way to find out.
            next if is_nonportable_line($line);

            print {$dst} $line or die "write $out: $!";
        }
        close $dst or die "close $out: $!";
        unlink $raw or die "unlink $raw: $!";

        warn "Schema dump written to $out\n";
        undef $template_db;
    }

    sub _load_from_dump {
        my ($self) = @_;
        my $uri  = $self->{pgsql}->uri;
        my $psql = _find_pg_tool('psql');

        # ON_ERROR_STOP, and stderr left alone. Without the flag psql exits 0
        # even when every statement in the file failed, so this `or die` could
        # not fire and every test in the suite would run against whatever
        # fraction of the schema happened to load. Safe to arm now that
        # generate_dump writes a portable file; before that it would have
        # rejected the dump on any server older than the one that made it.
        system("$psql -v ON_ERROR_STOP=1 '$uri' < '$DUMP_FILE' >/dev/null") == 0
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

        push @LIVE_INSTANCES, $self;
        Scalar::Util::weaken( $LIVE_INSTANCES[-1] );

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
            # Silence DBD::Pg destructors before stopping the server, so cached
            # statement/connection handles destroyed afterwards don't print
            # "terminating connection due to administrator command" noise.
            _neutralize_dbi_handles();
            # Stopping the server reaps the postmaster; localize $? so a
            # non-zero reap status cannot leak into the process exit code,
            # which prove would treat as a failed test file. See issue #186.
            local $?;
            undef $self->{pgsql};
        }
    }

    # Mark every open DBI connection InactiveDestroy so DBD::Pg's destructors
    # never execute against an about-to-stop server and emit "terminating
    # connection due to administrator command" -- noise that dirties the exit
    # code. See issue #186.
    sub _neutralize_dbi_handles {
        DBI->visit_handles(sub {
            my $h = shift;
            $h->{InactiveDestroy} = 1 if ( $h->{Type} // '' ) eq 'db';
            return 1;
        });
    }

    # Deterministic teardown at process exit. This runs before global
    # destruction, so we control the order: first silence the DBI handles,
    # then stop each ephemeral server under local $?. Without this, teardown
    # noise dirties the exit code and prove fails an otherwise-passing test
    # file -- the root cause behind #186.
    END {
        local $?;
        _neutralize_dbi_handles();
        for my $instance ( grep { defined } @LIVE_INSTANCES ) {
            $instance->cleanup_test_database;
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
