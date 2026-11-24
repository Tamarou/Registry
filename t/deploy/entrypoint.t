#!/usr/bin/env perl
# ABOUTME: The web entrypoint must refuse to boot when a migration, import or platform check fails.
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
# Every fake appends its name to calls.log, so a case can see what ran and in
# what order. `mode` sets MOJO_MODE; it defaults to unset, as in development.
sub run_entrypoint (%exit_for) {
    my $mode = delete $exit_for{mode} // '';
    my $dir = tempdir( CLEANUP => 1 );
    my $bin = "$dir/bin";
    mkdir $bin;

    # ./registry is called with a subcommand -- workflow, template, platform,
    # daemon -- so one shim covers them all and keys its exit code on $1, and
    # for `platform` on its own subcommand too.
    _shim( "$dir/registry", <<"SH" );
echo "registry \$1 \$2" >> "$dir/calls.log"
case "\$1 \$2" in
    workflow*)          exit @{[ $exit_for{workflow}  // 0 ]} ;;
    template*)          exit @{[ $exit_for{template}  // 0 ]} ;;
    "platform check")     exit @{[ $exit_for{check}     // 0 ]} ;;
    "platform bootstrap") exit @{[ $exit_for{bootstrap} // 0 ]} ;;
    *)                  exit 0 ;;
esac
SH

    _shim( "$bin/sqitch",
        qq{echo sqitch >> "$dir/calls.log"\nexit @{[ $exit_for{sqitch} // 0 ]}\n} );

    # The readiness loop sleeps a second per attempt, thirty times. A curl that
    # succeeds immediately keeps the happy-path case from taking half a minute.
    _shim( "$bin/curl", "exit 0\n" );

    my $cwd = getcwd();
    chdir $dir or die "chdir $dir: $!";
    my $output = qx{
        PATH="$bin:\$PATH" SERVICE_TYPE=web SQITCH_TARGET='db:pg://u:p\@h/db' \\
        MOJO_MODE='$mode' BASE_URL= PORT=1 bash "$entrypoint" 2>&1
    };
    my $status = $? >> 8;
    chdir $cwd or die "chdir back: $!";

    my @calls;
    if ( open my $log, '<', "$dir/calls.log" ) {
        chomp( @calls = <$log> );
        s/\s+\z// for @calls;
    }

    return ( $status, $output // '', \@calls );
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

# A refused boot that has already migrated leaves the database ahead of the
# code still serving, and that code then cannot restart: sqitch finds changes
# its plan does not list. So a production configuration that bootstrap would
# refuse is refused before sqitch runs, while the old code can still come back.
subtest 'a bad platform configuration stops a production boot before migrating' => sub {
    my ( $status, $out, $calls ) = run_entrypoint( mode => 'production', check => 1 );

    isnt $status, 0,
        'the entrypoint exits non-zero when the platform check fails';
    ok !( grep { $_ eq 'sqitch' } @$calls ),
        'and sqitch never runs'
        or diag explain $calls;
    unlike $out, qr/Server is ready/, 'and never reaches the server start';
};

subtest 'a production boot checks the platform before migrating' => sub {
    my ( $status, $out, $calls ) = run_entrypoint( mode => 'production' );

    is $status, 0, 'the entrypoint exits zero when everything succeeds';
    is_deeply [ grep { /\A(?:sqitch|registry platform)/ } @$calls ],
        [ 'registry platform check', 'sqitch', 'registry platform bootstrap' ],
        'the check runs first, then the migration, then the bootstrap';
};

subtest 'outside production a bad platform configuration does not stop the boot' => sub {
    my ( $status, $out, $calls ) = run_entrypoint( check => 1, bootstrap => 1 );

    is $status, 0,
        'a development stack boots without the platform variables';
    ok( ( grep { $_ eq 'sqitch' } @$calls ), 'and still migrates' );
};

subtest 'a clean deploy still boots' => sub {
    my ( $status, $out ) = run_entrypoint();

    is $status, 0, 'the entrypoint exits zero when everything succeeds';
    like $out, qr/Database schema deployed successfully/,
        'and says so';
};

done_testing;
