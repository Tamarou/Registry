# ABOUTME: Platform-owner CLI: see and change the configuration Alex owns.
# ABOUTME: The first piece of PriceOps Pillar 5 tooling -- changes through a tool, not psql (#427).
use 5.42.0;
use utf8;
use Object::Pad;

class Registry::Command::platform :isa(Mojolicious::Command) {
    use Registry::DAO::PlatformSetting;

    field $description :reader = 'Platform configuration';
    field $usage :reader       = <<~"END";
        usage: $0 platform <command> [<args>]

          commands:
            * settings           - list every platform setting and its value
            * set <key> <value>  - set one
            * unset <key>        - return one to its default

        END

    method run ( $cmd = '', @args ) {
        my $dao = $self->app->dao;

        if ( $cmd eq 'settings' ) {
            my $settings = Registry::DAO::PlatformSetting->all( $dao->db );

            unless (@$settings) {
                say 'No platform settings are defined.';
                return;
            }

            for my $s (@$settings) {
                # "not set" is printed as those words, never as blank. A blank
                # column reads as "set to nothing", and for this first key
                # nothing and 0 mean opposite things.
                say sprintf '%s = %s', $s->key,
                    defined $s->value ? $s->value : '(not set)';
                say '    ' . $s->description;
                say '    ' . $s->default_note;
                say '';
            }
            return;
        }

        if ( $cmd eq 'set' ) {
            my ( $key, @rest ) = @args;
            my $value = join ' ', @rest;

            unless ( defined $key && length $key && length $value ) {
                say 'usage: platform set <key> <value>';
                return;
            }

            eval {
                Registry::DAO::PlatformSetting->set( $dao->db, $key, $value );
                say "$key = $value";
                1;
            } or do {
                my $why = $@;
                $why =~ s/ at \S+ line \d+\.?\s*\z//;
                say $why;
                say 'Run `platform settings` to see the keys that exist.';
            };
            return;
        }

        if ( $cmd eq 'unset' ) {
            my ($key) = @args;
            unless ( defined $key && length $key ) {
                say 'usage: platform unset <key>';
                return;
            }

            eval {
                Registry::DAO::PlatformSetting->set( $dao->db, $key, undef );
                say "$key = (not set)";
                1;
            } or do {
                my $why = $@;
                $why =~ s/ at \S+ line \d+\.?\s*\z//;
                say $why;
            };
            return;
        }

        die "Unknown command `platform $cmd`\n" . $self->usage;
    }
}

1;
