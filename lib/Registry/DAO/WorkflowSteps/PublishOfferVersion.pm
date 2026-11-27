# ABOUTME: offer-publishing step: review the terms the run collected and publish them as an offer version.
# ABOUTME: Admin of the run's tenant only, one version per run; once published the database keeps it immutable.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::PublishOfferVersion :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Offer;
    use Registry::DAO::Project;
    use Registry::DAO::Resource;
    use Registry::DAO::Tenant;
    use Registry::DAO::WorkflowSteps::ChangePolicy;
    use Registry::DAO::WorkflowSteps::ExpiryPolicy;
    use Registry::DAO::WorkflowSteps::InstalmentPaymentPlan;
    use Registry::DAO::WorkflowSteps::MissedPaymentPolicy;
    use Registry::DAO::WorkflowSteps::OfferBasics;
    use Registry::DAO::WorkflowSteps::OfferConditions;
    use Registry::DAO::WorkflowSteps::OfferPrice;
    use Registry::DAO::WorkflowSteps::RefundPolicy;
    use Registry::DAO::WorkflowSteps::UsePolicy;
    use Registry::Utility::PriceFormat qw( format_price );

    # A stored fraction (at most 4 places, 0..1) as a percent, by moving the
    # decimal point in its digits: no float touches the rate on its way to the screen.
    sub percent_of ( $class, $fraction ) {
        my ( $whole, $part ) = $fraction =~ /\A([0-9]+)(?:\.([0-9]*))?\z/a
            or die "not a stored rate: $fraction\n";
        my $bp = $whole * 10_000 + substr( ( $part // '' ) . '0000', 0, 4 );
        my $percent = sprintf '%d.%02d', int( $bp / 100 ), $bp % 100;
        $percent =~ s/\.?0+\z// if $percent =~ /\./;
        return "$percent%";
    }

    method process ( $db, $form_data, $run = undef ) {
        return { stay => 1 } unless ( $form_data->{action} // '' ) eq 'publish';

        # The run's user, which the controller seeds server-side, never the
        # form's; and their role in the tenant whose schema the run is in.
        # The per-slug role gate does not cover a workflow staff composed
        # around this step themselves, so the step checks for itself.
        my $data   = $run->data;
        my $user   = ref $data->{user} eq 'HASH' ? $data->{user} : {};
        my $tenant = $db->query('SELECT current_schema()')->array->[0];
        return { stay => 1, errors => ['Only an administrator of this tenant can publish an offer'] }
            unless ( Registry::DAO::Tenant->role_in( $db, $tenant, $user->{id} ) // '' ) eq 'admin';

        my ( $basic, $price ) = $data->@{qw( offer_basics offer_price )};
        return { stay => 1, errors => ['Complete the offer and price steps before publishing'] }
            unless ref $basic eq 'HASH' && ref $price eq 'HASH';
        # A session run's offer is over some of its program's sessions, and
        # says who may choose it, as its steps recorded; asked again here.
        my $why;
        if ( $data->{session_program} ) {
            $why = Registry::DAO::WorkflowSteps::OfferBasics->session_refusal( $db, $data, $basic->{resource_ids} )
                // Registry::DAO::WorkflowSteps::OfferConditions->refusal( $db, $data, $data->{conditions} );
            return { stay => 1, errors => [$why] } if $why;
        }
        $why = Registry::DAO::WorkflowSteps::OfferPrice->refusal( $db, $data, $price->{units_per_acceptance} );
        return { stay => 1, errors => [$why] } if $why;

        # From the run, as the refund-policy step recorded it, never this form;
        # refused, never defaulted: absence is not a refund policy.
        my $refund = $data->{refund_policy};
        return { stay => 1, errors => ['Choose a refund policy before publishing'] }
            unless ref $refund eq 'HASH' && defined $refund->{kind} && !ref $refund->{kind};
        $why = Registry::DAO::WorkflowSteps::RefundPolicy->refusal( $db, $data, $refund );
        return { stay => 1, errors => [$why] } if $why;

        # From the run, as the change-policy step recorded it, never this form.
        my $change = $data->{change_policy};
        return { stay => 1, errors => ['Choose a change policy before publishing'] }
            unless ref $change eq 'HASH' && defined $change->{kind};
        $why = Registry::DAO::WorkflowSteps::ChangePolicy->refusal( $db, $data, $change );
        return { stay => 1, errors => [$why] } if $why;

        # From the run, as the use-policy step recorded it, never this form.
        my %use = ( ref $data->{use_policy} eq 'HASH' ? $data->{use_policy} : {} )->%*;
        return { stay => 1, errors => ['Choose a use policy before publishing'] }
            unless defined $use{use} && !ref $use{use};
        $why = Registry::DAO::WorkflowSteps::UsePolicy->refusal( $db, $data, \%use );
        return { stay => 1, errors => [$why] } if $why;
        my $expiry = ( ref $data->{expiry_policy} eq 'HASH' ? $data->{expiry_policy} : {} )->{expiry};
        return { stay => 1, errors => ['Choose an expiry policy before publishing'] }
            unless defined $expiry && !ref $expiry;
        $why = Registry::DAO::WorkflowSteps::ExpiryPolicy->refusal( $db, $data, $expiry );
        return { stay => 1, errors => [$why] } if $why;

        # Instalments say what a missed one does, and end by the session's
        # last day: asked again, since the resource can be chosen after the plan.
        my $parts  = ref $data->{instalment_payment} eq 'HASH' ? $data->{instalment_payment} : undef;
        my $missed = $data->{missed_payment_policy};
        if ($parts) {
            $why = Registry::DAO::WorkflowSteps::MissedPaymentPolicy->refusal( $db, $data, $missed );
            return { stay => 1, errors => [$why] } if $why;
            $why = Registry::DAO::WorkflowSteps::InstalmentPaymentPlan->refusal( $db, $data, $parts );
            return { stay => 1, errors => [$why] } if $why;
        }

        # Every plan a payment step declared; refused, never defaulted, when
        # none did: absence is not zero.
        my $percentage = $data->{percentage_of_sales_payment} // {};
        my @plans = (
            ( ( $data->{one_time_payment} // {} )->{one_time} // '' ) eq 'offered'
                ? { id => 'one_time', kind => 'one_time' } : (),
            ( $percentage->{percentage_of_sales} // '' ) eq 'offered'
                ? { id => 'percentage_of_sales', kind => 'percentage_of_sales', fraction => $percentage->{fraction} } : (),
            $parts ? { kind => 'instalments', $parts->%{qw( id count cadence surcharge_pct )} } : (),
        );
        return { stay => 1, errors => ['Offer at least one payment plan'] } unless @plans;

        # One version per run: the run's row is locked while this reads whether
        # it has published, so a repeated or concurrent submission waits and
        # then finds the first one's version instead of publishing another.
        my $tx = $db->dbh->{AutoCommit} ? $db->begin : undef;
        # In a caller's transaction, a savepoint, so a failure leaves nothing behind in it.
        $db->query('SAVEPOINT publish_offer_version') unless $tx;
        my $published = $db->query( q{
            SELECT data->>'published_offer_version_id' FROM workflow_runs WHERE id = ? FOR UPDATE
        }, $run->id )->array->[0];
        # Nothing is written on the early returns, so the savepoint is simply released.
        my $release = sub ($result) { $db->query('RELEASE SAVEPOINT publish_offer_version') unless $tx; $result };
        return $release->( { published_offer_version_id => $published } ) if $published;

        # Capacity asked again under the resource's row lock, which every grant
        # and hold takes first (Resource->locked), so a capacity lowered since
        # the check above is seen; a class's occurrences are locked in id order.
        $db->query( q{
            SELECT r.id FROM resources r LEFT JOIN events e ON e.id = r.event_id
             WHERE r.id = ? OR e.project_id = ? OR r.id::text = ANY(?) ORDER BY r.id FOR UPDATE OF r
        }, $basic->@{qw( resource_id class_project_id )}, $basic->{resource_ids} // [] );
        $why = Registry::DAO::WorkflowSteps::OfferPrice->refusal( $db, $data, $price->{units_per_acceptance} );
        return $release->( { stay => 1, errors => [$why] } ) if $why;

        my ( $stale, $at_guard );
        my $version = eval {
            # A new version of an existing offer is published only over the
            # version the run started from, read under the offer's lock: a
            # concurrent or earlier publish of it leaves this run with an error,
            # never two current versions or a newer one replaced unseen.
            my ( $offer, $current );
            if ( my $offer_id = $basic->{offer_id} ) {
                $db->query( 'SELECT 1 FROM offers WHERE id = ? FOR UPDATE', $offer_id );
                $offer   = Registry::DAO::Offer->find( $db, { id => $offer_id } );
                $current = $offer && $offer->current_version($db);
                unless ( $current && $current->id eq ( $basic->{based_on_version_id} // '' ) ) {
                    $stale = 1;
                    die "stale run\n";
                }
            }
            my $published = ( $offer // Registry::DAO::Offer->create( $db, { name => $basic->{offer_name} } ) )->draft( $db, {
                $basic->%{qw( resource_id class_project_id resource_ids )},    # one of them
                # Who may hold it carries over to a new version; a session run says.
                conditions => $current ? $current->conditions : $data->{conditions} // [],
                $price->%{qw( price_cents currency units_per_acceptance per_booking_cap )},
                payment_plans => \@plans,
                policies => { refund => $refund, change => $change, use => { kind => delete $use{use}, %use }, expiry => { kind => $expiry },
                    $parts ? ( missed_payment => $missed ) : () },
            } )->publish($db);
            # The platform-offer guard runs now, so its refusal is this step's error
            # rather than a failed commit; then deferred again, as a caller expects.
            $at_guard = 1;
            $db->query('SET CONSTRAINTS registry.offer_versions_keep_platform_offer IMMEDIATE');
            $at_guard = 0;
            $db->query('SET CONSTRAINTS registry.offer_versions_keep_platform_offer DEFERRED');
            $published;
        };
        # The detail can carry ids and driver messages, so it goes to the log
        # and the screen gets a fixed message; the transaction rolls back.
        unless ($version) {
            # RAISE EXCEPTION's SQLSTATE from that statement, where only the guard runs.
            my $guard_refused = $at_guard && ( $db->dbh->state // '' ) eq 'P0001';
            $db->query('ROLLBACK TO SAVEPOINT publish_offer_version') unless $tx;
            # A refusal the admin can act on, not an internal error.
            return { stay => 1, errors => ['A newer version of this offer was published since this run began; start again'] }
                if $stale;
            warn 'offer publish failed for run ' . $run->id . ": $@";
            return { stay => 1, errors => ['Publishing this would leave signup with no platform offer to tenants, so nothing was saved'] }
                if $guard_refused;
            return { stay => 1, errors => ['The offer could not be published, and nothing was saved. Please try again.'] };
        }
        $run->update_data( $db, { published_offer_version_id => $version->id } );
        $tx ? $tx->commit : $db->query('RELEASE SAVEPOINT publish_offer_version');

        return { published_offer_version_id => $version->id };
    }

    method prepare_template_data ( $db, $run, $params = {} ) {
        my $data  = $run->data;
        my $price = $data->{offer_price} // {};
        my $basic = $data->{offer_basics} // {};
        my ( $id, $class_id ) = $basic->@{qw( resource_id class_project_id )};
        return {
            %$data,
            sessions      => [ map { Registry::DAO::Resource->find( $db, { id => $_ } ) // () } ( $basic->{resource_ids} // [] )->@* ],
            resource      => $id ? Registry::DAO::Resource->find( $db, { id => $id } ) : undef,
            class         => $class_id ? Registry::DAO::Project->find( $db, { id => $class_id } ) : undef,
            price_display => format_price( $price->{price_cents}, $price->{currency} ),
            change_fee_display => defined( ( $data->{change_policy} // {} )->{fee_cents} )
                ? format_price( $data->{change_policy}{fee_cents}, $price->{currency} ) : undef,
            rate_display => defined( ( $data->{percentage_of_sales_payment} // {} )->{fraction} )
                ? __PACKAGE__->percent_of( $data->{percentage_of_sales_payment}{fraction} ) : undef,
        };
    }
}

1;
