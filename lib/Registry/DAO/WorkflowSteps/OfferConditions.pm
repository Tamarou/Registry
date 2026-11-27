# ABOUTME: session-setup step: who may choose the price: a sibling of a child holding a place, and only until an early-bird time.
# ABOUTME: The early-bird date and time is read in the program location's zone and stored as an instant (UTC).
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::OfferConditions :isa(Registry::DAO::WorkflowStep) {
    use DateTime;
    use Registry::DAO::WorkflowSteps::ChangePolicy;

    # The one shape this step stores an instant in.
    my $INSTANT = qr/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z/;

    # Why $conditions are not ones this step records, or nothing. Publish
    # asks again, since the offers a sibling's place counts from can go.
    sub refusal ( $class, $db, $data, $conditions ) {
        return 'Say who may choose this price' unless ref $conditions eq 'ARRAY';
        for my $condition (@$conditions) {
            my $kind = ref $condition eq 'HASH' ? $condition->{kind} // '' : '';
            if ( $kind eq 'family_holds_entitlement' ) {
                next if keys %$condition == 1;
                my $ids     = $condition->{offer_ids};
                my %current = map { $_->id => 1 } Registry::DAO::WorkflowSteps::ChangePolicy->current_offers($db)->@*;
                return q{Choose the offers a sibling's place counts from among your offers}
                    unless keys %$condition == 2 && ref $ids eq 'ARRAY' && @$ids
                    && !grep { !( defined && !ref && $current{$_} ) } @$ids;
            }
            elsif ( $kind eq 'before' ) {
                return 'The early-bird time is a date and time like 2027-03-01T00:00'
                    unless keys %$condition == 2 && ( $condition->{at} // '' ) =~ $INSTANT;
            }
            else {
                return 'Say who may choose this price';
            }
        }
        return;
    }

    method process ( $db, $form_data, $run = undef ) {
        my %f = map { $_ => ( ref $form_data->{$_} ? '' : $form_data->{$_} // '' ) } qw( sibling early_bird_until );
        return { stay => 1, errors => ['Say whether this price is for a sibling'] }
            unless $f{sibling} =~ /\A(?:none|any|offers)\z/;

        my @conditions;
        if ( $f{sibling} eq 'any' ) {
            push @conditions, { kind => 'family_holds_entitlement' };
        }
        elsif ( $f{sibling} eq 'offers' ) {
            my $ids = $form_data->{sibling_offer_ids};
            push @conditions, { kind => 'family_holds_entitlement',
                offer_ids => [ grep { defined && length } ref $ids eq 'ARRAY' ? @$ids : $ids // () ] };
        }

        my $until = $f{early_bird_until} =~ s/\A\s+|\s+\z//gr;
        if ( length $until ) {
            my @at = $until =~ /\A([0-9]{4})-([0-9]{2})-([0-9]{2})[T ]([0-9]{2}):([0-9]{2})\z/;
            return { stay => 1, errors => ['The early-bird time is a date and time like 2027-03-01T00:00'] }
                unless @at && eval {
                    DateTime->new( year => $at[0], month => $at[1], day => $at[2], hour => $at[3], minute => $at[4] );
                };
            # The local time in the program location's zone, as an instant.
            my $location = ( ( $run ? $run->data->{session_program} : undef ) // {} )->{location_id};
            my $instant  = $location && $db->query( q{
                SELECT to_char((?::timestamp AT TIME ZONE time_zone) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
                  FROM locations WHERE id = ?
            }, "$at[0]-$at[1]-$at[2] $at[3]:$at[4]", $location )->array;
            return { stay => 1, errors => ['Choose the program and its location again'] } unless $instant;
            push @conditions, { kind => 'before', at => $instant->[0] };
        }

        my $why = __PACKAGE__->refusal( $db, $run ? $run->data : {}, \@conditions );
        return { stay => 1, errors => [$why] } if $why;
        return { conditions => \@conditions };
    }

    method prepare_template_data ( $db, $run, $params = {} ) {
        my @conditions = ( $run->data->{conditions} // [] )->@*;
        my ($sibling)  = grep { $_->{kind} eq 'family_holds_entitlement' } @conditions;
        my ($before)   = grep { $_->{kind} eq 'before' } @conditions;
        my $location   = ( $run->data->{session_program} // {} )->{location_id};
        return {
            offers      => Registry::DAO::WorkflowSteps::ChangePolicy->current_offers($db),
            sibling     => !$sibling ? 'none' : $sibling->{offer_ids} ? 'offers' : 'any',
            sibling_ids => { map { $_ => 1 } ( $sibling && $sibling->{offer_ids} // [] )->@* },
            # Shown back in the location's zone, as it was entered.
            early_bird_until => $before && $location ? $db->query( q{
                SELECT to_char(?::timestamptz AT TIME ZONE time_zone, 'YYYY-MM-DD"T"HH24:MI') FROM locations WHERE id = ?
            }, $before->{at}, $location )->array->[0] : '',
        };
    }
}

1;
