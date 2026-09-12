#!/usr/bin/env perl
# ABOUTME: The web entrypoint must refuse to boot when a migration or import fails.
# ABOUTME: `set -e` is defeated by `if cmd; then`, so each command needs its own check.

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use File::Temp qw( tempdir );
use File::Spec;
use Cwd qw( getcwd );

# The entrypoint is the last thing standing between a failed deploy and a
# running site. Every RAISE EXCEPTION in sql/deploy/ -- the guards that refuse
# to leave the platform advertising a rate it cannot resolve, or a signup page
# with no buyable tier -- reaches production through this script. A failure it
# swallows is a guard that cannot fire.
#
# Bash's `set -e` does not help: a command inside `if cmd; then` is explicitly
# exempt, which is what made three failures here print a warning and carry on.

my $entrypoint = File::Spec->rel2abs('docker-entrypoint.sh');
ok -f $entrypoint, 'found docker-entrypoint.sh';

# Run the entrypoint in a sandbox: a temp cwd holding a fake ./registry, and a
# temp bin on PATH holding fake sqitch and curl. Each fake exits with the code
# named for it, so a case can fail exactly one command and leave the rest sound.
sub run_entrypoint (%exit_for) {
    my $dir = tempdir( CLEANUP => 1 );
    my $bin = "$dir/bin";
    mkdir $bin;

    # ./registry is called with a subcommand -- workflow, template, daemon --
    # so one shim covers all three and keys its exit code on $1.
    _shim( "$dir/registry", <<"SH" );
case "\$1" in
    workflow) exit @{[ $exit_for{workflow} // 0 ]} ;;
    template) exit @{[ $exit_for{template} // 0 ]} ;;
    *)        exit 0 ;;
esac
SH

    _shim( "$bin/sqitch", "exit @{[ $exit_for{sqitch} // 0 ]}\n" );

    # The readiness loop sleeps a second per attempt, thirty times. A curl that
    # succeeds immediately keeps the happy-path case from taking half a minute.
    _shim( "$bin/curl", "exit 0\n" );

    my $cwd = getcwd();
    chdir $dir or die "chdir $dir: $!";
    my $output = qx{
        PATH="$bin:\$PATH" SERVICE_TYPE=web SQITCH_TARGET='db:pg://u:p\@h/db' \\
        BASE_URL= PORT=1 bash "$entrypoint" 2>&1
    };
    my $status = $? >> 8;
    chdir $cwd or die "chdir back: $!";

    return ( $status, $output // '' );
}

sub _shim ( $path, $body ) {
    open my $fh, '>', $path or die "write $path: $!";
    print {$fh} "#!/bin/bash\n$body";
    close $fh;
    chmod 0755, $path or die "chmod $path: $!";
}

subtest 'a failed migration stops the boot' => sub {
    my ( $status, $out ) = run_entrypoint( sqitch => 1 );

    isnt $status, 0,
        'the entrypoint exits non-zero when sqitch deploy fails';
    unlike $out, qr/Starting the server|Server is ready/,
        'and never reaches the server start';
};

subtest 'a failed workflow import stops the boot' => sub {
    my ( $status, $out ) = run_entrypoint( workflow => 1 );

    isnt $status, 0,
        'the entrypoint exits non-zero when the workflow import fails';

    # Not a cosmetic failure: a signup page whose workflow never imported has
    # no steps to run, so the site comes up and cannot take a registration.
    unlike $out, qr/Server is ready/, 'and never reaches the server start';
};

subtest 'a failed template import stops the boot' => sub {
    my ( $status, $out ) = run_entrypoint( template => 1 );

    isnt $status, 0,
        'the entrypoint exits non-zero when the template import fails';
};

subtest 'a clean deploy still boots' => sub {
    my ( $status, $out ) = run_entrypoint();

    is $status, 0, 'the entrypoint exits zero when everything succeeds';
    like $out, qr/Database schema deployed successfully/,
        'and says so';
};

done_testing;
