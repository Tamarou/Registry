# ABOUTME: session-checkout step: one cart line per child and session, at a price the child qualifies for and a payment plan that fits.
# ABOUTME: Earlier lines count toward a sibling price; the cheapest choosable price is preselected; the /terms agreement is taken here.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::SessionCart :isa(Registry::DAO::WorkflowStep) {
    use POSIX qw( strftime );
    use Registry::DAO::Family;
    use Registry::DAO::Offer;
    use Registry::DAO::OfferVersion;
    use Registry::DAO::Resource;
    use Registry::PriceOps::Instalments qw( parts );
    use Registry::Terms ();
    use Registry::DAO::WorkflowSteps::ChooseOccurrence;
    use Registry::DAO::WorkflowSteps::ChooseOfferAndUnits;
    use Registry::DAO::WorkflowSteps::InstalmentPaymentPlan;

    my $UUID   = qr/\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/i;
    my @FIELDS = qw( family_member_id resource_id offer_version_id payment_plan_id );
    my $UNFIT  = 'Not offered: the last payment would fall after the session ends';

    method process ( $db, $form_data, $run = undef ) {
        my $data   = $run->data // {};
        my $lines  = ref $data->{cart_lines} eq 'ARRAY' ? $data->{cart_lines} : [];
        my $action = $form_data->{action} // '';
        if ( $action eq 'add_line' ) {
            my $choice = $form_data->{choice};
            my ( $version, $plan ) = !ref $choice && ( $choice // '' ) =~ m{\A([^/]+)/(.+)\z};
            my $added = [ @$lines, {
                family_member_id => $form_data->{family_member_id}, resource_id => $form_data->{resource_id},
                offer_version_id => $version, payment_plan_id => $plan,
            } ];
            my $why = __PACKAGE__->refusal( $db, $data, $added );
            return $why ? { stay => 1, errors => [$why] } : { stay => 1, cart_lines => $added };
        }
        return { stay => 1 } unless $action eq 'checkout';
        return { stay => 1, errors => ['Choose a session for at least one child'] } unless @$lines;
        # Asked again: a session may have filled or a price ended since its line.
        my $why = __PACKAGE__->refusal( $db, $data, $lines )
            // Registry::Terms::record_agreement( $db, $run, $form_data );
        return $why ? { stay => 1, errors => [$why] } : {};
    }

    sub now_instant ($class) { strftime '%Y-%m-%dT%H:%M:%SZ', gmtime }

    # Session $id when a line may take a seat in it now: a session, on sale.
    sub session_on_sale ( $class, $db, $id ) {
        return undef unless defined $id && !ref $id && $id =~ $UUID;
        my $session = Registry::DAO::Resource->find( $db, { id => $id } ) or return undef;
        return $session->is_session($db) && $session->on_sale($db) ? $session : undef;
    }

    # The versions buying session $resource_id that child $child may choose at
    # $at, given the cart's earlier $lines, cheapest first.
    sub choosable ( $class, $db, $resource_id, $child, $lines, $at ) {
        my @earlier = map { {
            family_member_id => $_->{family_member_id},
            offer_id => Registry::DAO::OfferVersion->find( $db, { id => $_->{offer_version_id} } )->offer_id,
        } } @$lines;
        return [ map { $_->{version} } grep { !$_->{unmet}->@* }
                Registry::DAO::OfferVersion->choosable_for( $db, $resource_id,
                { holder_family_member_id => $child, at => $at, cart_lines => \@earlier } )->@* ];
    }

    # $version's plans a parent may pay session $resource_id by, each with
    # `fits`: whether an instalment plan's last payment, bought today, falls
    # on or before the session's last day.
    sub plans ( $class, $db, $version, $resource_id ) {
        return [ map {
            { %$_, fits => $_->{kind} eq 'one_time' || !Registry::DAO::WorkflowSteps::InstalmentPaymentPlan->refusal(
                    $db, { offer_basics => { resource_id => $resource_id } }, $_ ) }
        } grep { $_->{kind} eq 'one_time' || $_->{kind} eq 'instalments' } $version->payment_plans($db)->@* ];
    }

    # Why the cart $lines may not be bought by the run's signed-in payer now,
    # or nothing. Each line's child is the payer's, its session is on sale with
    # room for the cart's lines in it, its version is choosable for that child
    # given the earlier lines, its plan is one of that version's and fits, and
    # a child is in a session at most once.
    sub refusal ( $class, $db, $data, $lines ) {
        my $payer = $data->{user_id};
        return 'Sign in to book' unless defined $payer && !ref $payer && $payer =~ $UUID;
        my %mine = map { $_->id => 1 } Registry::DAO::Family->list_children( $db, $payer )->@*;
        my $at   = $class->now_instant;
        my ( @earlier, %seen, %taking );
        for my $line (@$lines) {
            return 'Choose one of the listed prices'
                if ref $line ne 'HASH' || grep { !defined || ref } $line->@{@FIELDS};
            my ( $child, $resource_id, $version_id, $plan_id ) = $line->@{@FIELDS};
            return 'Choose one of your own children' unless $mine{$child};
            my $session = $class->session_on_sale( $db, $resource_id )
                or return 'Choose one of the listed sessions';
            return 'A child can be in a session only once' if $seen{"$child $resource_id"}++;
            return sprintf '%s is full', $session->name if ++$taking{$resource_id} > $session->free_units($db);
            my ($version) = grep { $_->id eq $version_id }
                $class->choosable( $db, $resource_id, $child, \@earlier, $at )->@*
                or return 'Choose one of the listed prices';
            my ($plan) = grep { $_->{id} eq $plan_id } $class->plans( $db, $version, $resource_id )->@*
                or return 'Choose one of the listed payment plans';
            return $UNFIT unless $plan->{fits};
            push @earlier, $line;
        }
        return;
    }

    sub policy_words ( $class, $version ) {
        Registry::DAO::WorkflowSteps::ChooseOfferAndUnits->policy_words($version);
    }

    my sub dollars ($cents) { sprintf '%.2f', $cents / 100 }

    # What paying by $plan for $version means, in words.
    my sub plan_words ( $plan, $version ) {
        return "Pay \$${\ dollars( $version->price_cents ) } now" if $plan->{kind} eq 'one_time';
        return $UNFIT unless $plan->{fits};
        return sprintf 'Pay in %d %s payments of $%s', $plan->@{qw( count cadence )},
            dollars( parts( $version->price_cents, $plan, '2000-01-01' )->[0]{amount_cents} );
    }

    # The payer's chosen children, eldest first, each with every session on
    # sale: the prices the child may choose for its next line, or full.
    method prepare_template_data ( $db, $run, $params = {} ) {
        my $data  = $run->data // {};
        my $payer = $data->{user_id};
        return { children => [], lines => [] } unless defined $payer && !ref $payer && $payer =~ $UUID;
        my $lines  = ref $data->{cart_lines} eq 'ARRAY' ? $data->{cart_lines} : [];
        my %chosen = map { $_ => 1 } grep { defined && !ref }
            ( ref $data->{selected_child_ids} eq 'ARRAY' ? $data->{selected_child_ids}->@* : () );
        my @children = grep { $chosen{ $_->id } } Registry::DAO::Family->list_children( $db, $payer )->@*;
        my %name     = map { $_->id => $_->child_name } @children;

        my %seen;
        my @sessions = sort { $a->[1] cmp $b->[1] || $a->[0]->name cmp $b->[0]->name }
            map { [ $_, ( $_->occurrence_window($db) )[0] ] }
            grep { !$seen{ $_->id }++ && $_->is_session($db) && $_->on_sale($db) }
            map { $_->covered_resources($db)->@* }
            Registry::DAO::WorkflowSteps::ChooseOccurrence->current_versions($db)->@*;
        my $at = __PACKAGE__->now_instant;
        my sub offer_name ($version) { Registry::DAO::Offer->find( $db, { id => $version->offer_id } )->name }

        my @shown = map {
            my $child = $_;
            { id => $child->id, name => $child->child_name, sessions => [ map {
                my $session = $_->[0];
                my $taken   = grep { $_->{resource_id} eq $session->id } @$lines;
                my @prices  = $session->free_units($db) > $taken ? map {
                    my $version = $_;
                    { id => $version->id, name => offer_name($version), price => dollars( $version->price_cents ),
                      policy => __PACKAGE__->policy_words($version),
                      plans  => [ map { { id => $_->{id}, fits => $_->{fits}, words => plan_words( $_, $version ) } }
                                  __PACKAGE__->plans( $db, $version, $session->id )->@* ] }
                } __PACKAGE__->choosable( $db, $session->id, $child->id, $lines, $at )->@* : ();
                # The cheapest price's first plan that fits.
                my ($first) = map { my $v = $_; map { "$v->{id}/$_->{id}" } grep { $_->{fits} } $v->{plans}->@* } @prices;
                { id => $session->id, name => $session->name, full => !@prices && $session->free_units($db) <= $taken,
                  prices => \@prices, preselected => $first // '' }
            } @sessions ] }
        } @children;

        return {
            children => \@shown,
            lines    => [ map {
                my $version = Registry::DAO::OfferVersion->find( $db, { id => $_->{offer_version_id} } );
                my $line    = $_;
                my ($plan)  = grep { $_->{id} eq $line->{payment_plan_id} }
                    __PACKAGE__->plans( $db, $version, $line->{resource_id} )->@*;
                { child   => $name{ $line->{family_member_id} } // '',
                  session => Registry::DAO::Resource->find( $db, { id => $line->{resource_id} } )->name,
                  offer   => offer_name($version), price => dollars( $version->price_cents ),
                  plan    => $plan ? plan_words( $plan, $version ) : '' }
            } @$lines ],
        };
    }
}

1;
