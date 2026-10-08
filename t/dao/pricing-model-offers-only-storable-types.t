# ABOUTME: The pricing-model step offers only the model types the database will accept.
# ABOUTME: usage_based was selectable and rejected by the CHECK constraint, so the option was a dead end.
#
# #273. PricingModel offered "Usage-Based", branched on it, and built a
# usage_metric/rate_per_unit config for it -- and
# pricing_plans_pricing_model_type_check permits only fixed, percentage,
# tiered, hybrid and transaction_fee. The only migration that would have added
# it was never planned and has been deleted. perigrin's call: drop the option,
# Registry does not need usage-based billing yet. Future work is tracked
# separately.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use experimental 'signatures';
use Mojo::File qw( path );

use Test::Registry::DB;
use Registry::DAO;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

subtest 'the database would reject it, which is why the option goes' => sub {
    # The reason, asserted rather than asserted-about. If someone widens the
    # constraint later this fails and points at the option that can come back.
    my $allowed = $db->query( <<~'SQL' )->hash;
        SELECT pg_get_constraintdef(oid) AS def
          FROM pg_constraint
         WHERE conname = 'pricing_plans_pricing_model_type_check'
        SQL
    ok $allowed, 'the constraint exists';
    unlike $allowed->{def}, qr/usage_based/,
        'and does not permit usage_based';

    my $rejected = !eval {
        $db->query( <<~'SQL' );
            INSERT INTO registry.pricing_plans
                   (plan_name, plan_type, pricing_model_type)
            VALUES ('Usage Dead End', 'standard', 'usage_based')
            SQL
        1;
    };
    ok $rejected, 'a usage_based plan cannot be stored at all';
};

# Comments stripped before matching. The step carries a note explaining why the
# option is absent -- which is the thing that stops it being helpfully re-added
# -- and an assertion that forbade naming it at all would forbid the warning too.
sub code_of ($file) {
    my $src = path($file)->slurp;
    $src =~ s{^\s*#.*$}{}mg;
    return $src;
}

subtest 'the step offers no usage_based option' => sub {
    my $src = code_of('lib/Registry/DAO/WorkflowSteps/PricingModel.pm');

    unlike $src, qr/usage_based/,
        'the step neither offers it, validates it, nor configures it';

    # The menu still has to offer everything the constraint allows, or the
    # removal has quietly taken a working type with it.
    like $src, qr/value => '$_'/, "still offers $_"
        for qw( fixed percentage tiered hybrid transaction_fee );
};

subtest 'the form script does not reveal a section for it either' => sub {
    my $tpl = code_of('templates/pricing-plan-creation/pricing-model.html.ep');
    unlike $tpl, qr/usage_based/,
        'the advanced-config toggle no longer names a type that cannot be saved';
};

subtest 'every type the step offers can actually be stored' => sub {
    # The assertion that would have caught #273 when it was introduced, and
    # catches the next one: offered and storable are the same set.
    my $src = code_of('lib/Registry/DAO/WorkflowSteps/PricingModel.pm');
    my ($menu) = $src =~ /pricing_model_types\s*=>\s*\[(.*?)\]/s;
    ok $menu, 'found the offered list';
    my @offered = $menu =~ /value\s*=>\s*'([a-z_]+)'/g;
    ok scalar @offered, 'it offers something';

    for my $type (@offered) {
        my $ok = eval {
            $db->query( <<~'SQL', "Storable $type", $type );
                INSERT INTO registry.pricing_plans
                       (plan_name, plan_type, pricing_model_type)
                VALUES (?, 'standard', ?)
                SQL
            1;
        };
        ok $ok, "a plan the form offers as '$type' can be stored"
            or diag $@;
    }
};

done_testing;
