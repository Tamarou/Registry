#!/usr/bin/env perl
# ABOUTME: Tests for the shared fixture date helpers in Test::Registry::Helpers.
# ABOUTME: Fixture dates must be derived from the run date, so the derivation itself needs proof.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Time::Local qw( timelocal_posix );
use POSIX qw( tzset );
use Test::Registry::Helpers;
use Registry::DAO::FamilyMember;

# A date that is $days from $now, computed independently of the helper:
# calendar arithmetic anchored at noon, so a DST shift cannot move the day.
sub reference_date ( $days, $now ) {
    my ( $y, $m, $d ) = ( localtime $now )[ 5, 4, 3 ];
    my @t = localtime( timelocal_posix( 0, 0, 12, $d, $m, $y ) + $days * 86_400 );
    return sprintf '%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3];
}

sub family_member ( $birth_date ) {
    return Registry::DAO::FamilyMember->new(
        id         => 'test', family_id => 'test', child_name => 'test',
        grade      => '3',    birth_date => $birth_date,
        created_at => 'now',  updated_at => 'now',
    );
}

subtest 'days_from_now formats and orders' => sub {
    like days_from_now(0), qr/^\d{4}-\d{2}-\d{2}$/, 'YYYY-MM-DD';
    ok days_from_now(30) gt days_from_now(0),  'a future offset sorts after today';
    ok days_from_now(-30) lt days_from_now(0), 'a negative offset sorts before today';
    is days_from_now(0), reference_date( 0, time ), 'zero offset is today';
};

# The helper exists so that a fixture written today is still in the future
# tomorrow. An off-by-one at a month, year or DST boundary would put a
# session on the wrong side of `end_date >= CURRENT_DATE`, which is the
# silent failure the helper is meant to prevent.
subtest 'days_from_now is exact across every day of a year' => sub {

    # CI runs in UTC, where a clock that never shifts cannot demonstrate the
    # boundary this helper exists to survive. Sweep a zone that observes
    # daylight saving as well as the ambient one.
    for my $zone ( $ENV{TZ} // '', 'America/New_York' ) {
        local $ENV{TZ} = $zone;
        tzset;

        my @wrong;
        my $start = timelocal_posix( 0, 0, 0, 1, 0, 126 );    # 2026-01-01
        my $shifted = 0;

        for my $day ( 0 .. 364 ) {
            my $noon = $start + $day * 86_400 + 43_200;
            $shifted++ if ( localtime $noon )[2] != 12;

            for my $hour ( 0, 23 ) {
                my $now = $start + $day * 86_400 + $hour * 3_600 + 1_800;
                for my $offset ( -365, -30, -1, 0, 1, 30, 365 ) {
                    my $got  = days_from_now( $offset, $now );
                    my $want = reference_date( $offset, $now );
                    push @wrong, "$got != $want (offset $offset from " . reference_date( 0, $now ) . " ${hour}:30)"
                      unless $got eq $want;
                }
            }
        }

        my $label = $zone || 'the ambient zone';
        is scalar @wrong, 0, "every offset lands on the right day in $label"
          or diag join "\n", @wrong[ 0 .. ( @wrong < 10 ? $#wrong : 9 ) ];

        # Without a real transition the sweep above proves nothing about DST,
        # so say so rather than passing quietly on missing tzdata.
        ok $shifted, 'America/New_York shifts its clock during the year'
          if $zone eq 'America/New_York';
    }

    tzset;
};

# Age eligibility is checked by Registry::DAO::FamilyMember::age, so the
# helper is measured against that rule rather than against a copy of it.
subtest 'birth_date_for_age agrees with FamilyMember::age' => sub {
    my @wrong;
    for my $month ( 0 .. 11 ) {
        for my $day ( 1, 15, 28 ) {
            my $now = timelocal_posix( 0, 0, 12, $day, $month, 126 );
            for my $age ( 3 .. 18 ) {
                my $birth_date = birth_date_for_age( $age, $now );
                my $got        = family_member($birth_date)->age($now);
                push @wrong, "$birth_date is $got, not $age (as of " . reference_date( 0, $now ) . ')'
                  unless $got == $age;
            }
        }
    }
    is scalar @wrong, 0, 'the derived birth date yields exactly that age'
      or diag join "\n", @wrong[ 0 .. ( @wrong < 10 ? $#wrong : 9 ) ];
};

# A birthday landing on the day the suite runs would make the child's age
# flip mid-run. The helper puts it half a year away from that.
subtest 'birth_date_for_age keeps the birthday away from today' => sub {
    my @close;
    for my $month ( 0 .. 11 ) {
        my $now = timelocal_posix( 0, 0, 12, 15, $month, 126 );
        my $birth_date = birth_date_for_age( 8, $now );
        my ( undef, $birth_month, $birth_day ) = split /-/, $birth_date;

        my $age_yesterday = family_member($birth_date)->age( $now - 86_400 );
        my $age_tomorrow  = family_member($birth_date)->age( $now + 86_400 );
        push @close, "$birth_date changes age around " . reference_date( 0, $now )
          unless $age_yesterday == 8 && $age_tomorrow == 8;
    }
    is scalar @close, 0, 'the age is stable on either side of the run date'
      or diag join "\n", @close;
};

done_testing;
