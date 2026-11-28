# ABOUTME: Test helper leaving a paid session cart charge and one child's instalment entitlement, as checkout does.
# ABOUTME: The charge carries metadata.lines with the plan's parts; schedule_instalments_for reads them from there.
use 5.42.0;
use warnings;

package Test::Registry::InstalmentCheckout;

use Exporter 'import';
our @EXPORT_OK = qw( instalment_checkout );

use DateTime;
use Test::Registry::Fixtures;
use Test::Registry::Offers qw( instalment_plan );
use Test::Registry::Sessions qw( make_session session_offer );
use Registry::PriceOps::Instalments ();
use Registry::DAO::FamilyMember;
use Registry::DAO::Entitlement;
use Registry::DAO::Payment;

my $made = 0;

# instalment_checkout($db, %o): { payment, entitlement, line, plan, session,
# version, parent } for one child paying a session in instalments. %o: count
# (3) and cadence (monthly) of the plan, price_cents (10000), first_date
# (today), parent (a user id), slug (the charge's tenant_slug, which names
# the Stripe account it was made on) and status (completed).
sub instalment_checkout ( $db, %o ) {
    my $n    = ++$made;
    my $plan = instalment_plan( count => $o{count} // 3, cadence => $o{cadence} // 'monthly' );

    # Late enough that any plan bought today fits before the last day.
    my $session = make_session( $db, days => [qw( 2029-06-04 2029-06-05 )] );
    my $version = session_offer( $db, $session,
        price_cents   => $o{price_cents} // 10000,
        payment_plans => [$plan],
        policies      => { refund => { kind => 'none' }, missed_payment => { kind => 'keep_and_owe' } } );

    my $parent = $o{parent}
        // Test::Registry::Fixtures::create_user( $db, { username => "ic-parent-$n-$$" } )->id;
    my $child = Registry::DAO::FamilyMember->create( $db,
        { family_id => $parent, child_name => "Instalment child $n", birth_date => '2018-05-01' } )->id;

    my $parts = Registry::PriceOps::Instalments::parts( $version->price_cents, $plan,
        $o{first_date} // DateTime->today->ymd );
    my $line = {
        family_member_id => $child,
        resource_id      => $session->id,
        offer_version_id => $version->id,
        payment_plan_id  => $plan->{id},
        kind             => 'instalments',
        share_cents      => $parts->[0]{amount_cents},
        parts            => $parts,
    };

    my $payment = Registry::DAO::Payment->create( $db, {
        user_id                  => $parent,
        amount_cents             => $line->{share_cents},
        currency                 => 'USD',
        status                   => $o{status} // 'completed',
        stripe_payment_intent_id => "pi_checkout_${n}_$$",
        metadata => { ( $o{slug} ? ( tenant_slug => $o{slug} ) : () ), lines => [$line] },
    } );

    my $entitlement = Registry::DAO::Entitlement->grant( $db, {
        holder_family_member_id => $child,
        payer_user_id           => $parent,
        offer_version_id        => $version->id,
        payment_plan_id         => $plan->{id},
        starts_at               => 'now',
        resource_id             => $session->id,
        units                   => 1,
        payment_id              => $payment->id,
        payment_share_cents     => $line->{share_cents},
    } );

    return { payment => $payment, entitlement => $entitlement, line => $line, plan => $plan,
             session => $session, version => $version, parent => $parent };
}

1;
