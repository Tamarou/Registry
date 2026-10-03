#!/usr/bin/env perl
# ABOUTME: In production the app states its effective configuration at boot, and names what is missing.
# ABOUTME: LOG_LEVEL was committed, never arrived, and nothing said so for hours -- #459.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use experimental 'signatures';
use Mojo::JSON qw(decode_json);
use Test::Registry::DB;
use Registry;

my $test_db = Test::Registry::DB->new;
$ENV{DB_URL} = $test_db->uri;

# Boot an app and return the structured lines it wrote while starting up.
sub boot_lines ( %env ) {
    # Saved and restored by hand, not with `local`. `local $ENV{$_} = ... for ...`
    # is a statement-modifier loop, so each localisation unwinds at the end of
    # that statement and nothing persists into the call below -- which made the
    # first version of this file assert against the ambient environment instead
    # of the one it set up. The workstation exports a live STRIPE_SECRET_KEY, so
    # "absent" was not absent and the missing-configuration subtest passed for
    # the wrong reason.
    my %saved = map { $_ => $ENV{$_} } ( keys %env, 'MOJO_SECRET' );

    $ENV{MOJO_SECRET} = 'boot-config-test-secret';
    for my $key ( keys %env ) {
        if ( defined $env{$key} ) { $ENV{$key} = $env{$key} }
        else                      { delete $ENV{$key} }
    }

    my $buf = '';
    open my $fh, '>', \$buf or die "cannot open scalar handle: $!";

    my $app = Registry->new( mode => 'production' );
    $app->log->handle($fh);
    $app->log->level('debug');
    $app->_log_effective_configuration;

    my $lines = [ grep { ref $_ eq 'HASH' }
                  map  { my $e = eval { decode_json($_) }; $e }
                  grep { /^\{/ } split /\n/, $buf ];

    for my $key ( keys %saved ) {
        if ( defined $saved{$key} ) { $ENV{$key} = $saved{$key} }
        else                        { delete $ENV{$key} }
    }

    return $lines;
}

subtest 'it states the configuration it is actually running with' => sub {
    my $lines = boot_lines(
        LOG_LEVEL             => 'debug',
        BASE_URL              => 'https://example.test',
        STRIPE_SECRET_KEY     => 'sk_test_boot',
        STRIPE_WEBHOOK_SECRET => 'whsec_boot',
        POSTMARK_SERVER_TOKEN => 'pm-boot',
    );

    my ($config) = grep { ( $_->{message} // '' ) =~ /effective configuration/i } @$lines;
    ok $config, 'a boot line reports the effective configuration';

    like $config->{message}, qr/LOG_LEVEL=debug/,
        'naming the value actually in force, which is the whole point';
    like $config->{message}, qr{BASE_URL=https://example\.test}, 'and the base url';
};

subtest 'a secret is reported as present, never echoed' => sub {
    my $lines = boot_lines(
        LOG_LEVEL             => 'debug',
        BASE_URL              => 'https://example.test',
        STRIPE_SECRET_KEY     => 'sk_test_do_not_echo_me',
        STRIPE_WEBHOOK_SECRET => 'whsec_boot',
        POSTMARK_SERVER_TOKEN => 'pm-boot',
    );

    my $all = join "\n", map { $_->{message} // '' } @$lines;

    unlike $all, qr/sk_test_do_not_echo_me/, 'the key itself is not in the log';
    like $all, qr/STRIPE_SECRET_KEY=set/, 'only that it is set';
};

subtest 'what is missing is named, with what it costs' => sub {
    # The shape of #459: the variable is simply absent, the app boots fine, and
    # the behaviour it was for silently does not happen.
    my $lines = boot_lines(
        LOG_LEVEL             => undef,
        BASE_URL              => undef,
        STRIPE_SECRET_KEY     => undef,
        STRIPE_WEBHOOK_SECRET => undef,
        POSTMARK_SERVER_TOKEN => undef,
    );

    my @errors = grep { ( $_->{level} // '' ) eq 'error' } @$lines;
    ok scalar @errors, 'absent configuration is an error, not a shrug';

    my $all = join "\n", map { $_->{message} // '' } @errors;

    # Each consequence is one I verified in the code rather than guessed.
    like $all, qr/STRIPE_SECRET_KEY.*charg/is,
        'no Stripe key means paid enrolments complete without charging';
    like $all, qr/STRIPE_WEBHOOK_SECRET.*(settle|webhook)/is,
        'no webhook secret means settlements never complete';
    like $all, qr/POSTMARK_SERVER_TOKEN.*mail|POSTMARK_SERVER_TOKEN.*email/is,
        'no Postmark token means no email is delivered';
    like $all, qr/BASE_URL/, 'no base url is named too';
    like $all, qr/LOG_LEVEL/, 'and the one that started this';
};

subtest 'a fully configured production says nothing is missing' => sub {
    my $lines = boot_lines(
        LOG_LEVEL             => 'debug',
        BASE_URL              => 'https://example.test',
        STRIPE_SECRET_KEY     => 'sk_test_boot',
        STRIPE_WEBHOOK_SECRET => 'whsec_boot',
        POSTMARK_SERVER_TOKEN => 'pm-boot',
    );

    my @errors = grep { ( $_->{level} // '' ) eq 'error' } @$lines;
    is scalar @errors, 0, 'nothing is reported absent when nothing is';
};

done_testing;
