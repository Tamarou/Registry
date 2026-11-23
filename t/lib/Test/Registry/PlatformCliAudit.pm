# ABOUTME: Test helper: which `registry platform` subcommands have neither an admin screen nor a deploy-only place.
# ABOUTME: Used by t/security/platform-cli-has-admin-screen.t on the real usage text and on fixtures.
use 5.42.0;

package Test::Registry::PlatformCliAudit;

# Reads the `* <name>` lines of a command's usage text -- the list a person
# reads, so a subcommand cannot be added without appearing here -- and returns,
# in usage order, every one that has no admin route in %$screen_for and is not
# in @$deploy_only.
sub unmapped ( $usage_text, $screen_for, $deploy_only ) {
    my %deploy_only = map { $_ => 1 } @$deploy_only;
    return grep { !$screen_for->{$_} && !$deploy_only{$_} }
        $usage_text =~ /^\s*\*\s+(\S+)/mg;
}

1;
