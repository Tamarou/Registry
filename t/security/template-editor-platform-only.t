#!/usr/bin/env perl
# ABOUTME: Saving or reverting .ep template text is the platform operator's alone: the text runs as Perl on the server.
# ABOUTME: Drives the template-editor step through real runs as studio admin/staff, registry staff and the operator admin.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( import_all_workflows join_tenant );
use Test::Registry::OperatorRight qw( revoke_operator restore_operator );
use Registry::DAO;
use Registry::DAO::Template;
use Registry::DAO::Tenant;
use Registry::DAO::Workflow;
use Registry::Utility::WorkflowProcessor;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $SLUG = 'ep_studio';
import_all_workflows($dao);
Test::Registry::Fixtures::create_tenant( $dao, { name => 'Ep Studio', slug => $SLUG } );
my $tenant_dao = Registry::DAO->new( url => $test_db->uri, schema => $SLUG );
my $tdb        = $tenant_dao->db;
import_all_workflows($tenant_dao);

my $operator = Registry::DAO::Tenant->platform($db)->primary_user($db);
ok Registry::DAO::Tenant->admin_of_holder( $db, $operator->id, 'operator' ),
    'the platform owner is an admin of the operator holder';

my %user = ( operator => $operator );
for my $who ( [ studio_admin => admin => $SLUG ], [ studio_staff => staff => $SLUG ],
    [ registry_staff => staff => 'registry' ] )
{
    my ( $name, $role, $slug ) = @$who;
    $user{$name} = Test::Registry::Fixtures::create_user( $dao,
        { username => "ep_$name", name => "Ep $name", email => "$name\@ep.test", user_type => $role } );
    join_tenant( $dao, $user{$name}, $role, $slug );
}

my $ORIGINAL = '<h1>Original</h1>';
my $DEFAULT  = '<h1>Platform default</h1>';
my $EVIL     = '<% system("id") %>';

# registry's copy is the canonical one revert reads; the studio's is its own.
my %tmpl = (
    registry => Registry::DAO::Template->create( $db,  { name => 'ep/page', slug => 'ep-page', content => $DEFAULT } ),
    $SLUG    => Registry::DAO::Template->create( $tdb, { name => 'ep/page', slug => 'ep-page', content => $ORIGINAL } ),
);
my %handle = ( registry => $dao, $SLUG => $tenant_dao );
my %start  = ( registry => $DEFAULT, $SLUG => $ORIGINAL );

# Runs the editor step in $schema as $who with $form; returns the result.
sub edit_as ( $who, $schema, $form ) {
    my $h        = $handle{$schema};
    my $workflow = $h->find( Workflow => { slug => 'template-editor' } );
    my $run      = Registry::WorkflowProcessor->new( dao => $h )
        ->new_run( $workflow, { user => { id => $user{$who}->id, name => $user{$who}->name } } );
    my $step = $workflow->get_step( $h->db, { slug => 'editor' } );
    return $run->process( $h->db, $step, { template_id => $tmpl{$schema}->id, %$form } );
}

sub content_in ($schema) { Registry::DAO::Template->find( $handle{$schema}->db, { id => $tmpl{$schema}->id } )->content }

sub reset_content () {
    $handle{$_}->db->update( 'templates', { content => $start{$_} }, { id => $tmpl{$_}->id } ) for keys %handle;
}

subtest 'template-editor declares admin only' => sub {
    is_deeply $dao->find( Workflow => { slug => 'template-editor' } )->roles, ['admin'], 'roles are [admin]';
};

for my $case (
    [ studio_admin   => $SLUG ],
    [ studio_staff   => $SLUG ],
    [ registry_staff => 'registry' ],
    [ operator       => $SLUG ],    # the operator, but not in the platform's schema
  )
{
    my ( $who, $schema ) = @$case;
    subtest "$who in $schema is refused save and revert" => sub {
        reset_content();
        my $result = edit_as( $who, $schema, { action => 'save', content => $EVIL } );
        ok $result->{errors}, 'save is refused';
        is content_in($schema), $start{$schema}, 'the stored template is unchanged by save';

        $result = edit_as( $who, $schema, { action => 'revert' } );
        ok $result->{errors}, 'revert is refused';
        is content_in($schema), $start{$schema}, 'the stored template is unchanged by revert';
    };
}

subtest 'a registry admin without the operator right is refused' => sub {
    reset_content();
    my $held = revoke_operator($db);
    my $result = edit_as( operator => registry => { action => 'save', content => $EVIL } );
    ok $result->{errors}, 'save is refused once registry no longer holds operator';
    is content_in('registry'), $DEFAULT, 'the stored template is unchanged';
    restore_operator( $db, $held );
};

subtest 'the platform operator admin may save and revert' => sub {
    reset_content();
    my $result = edit_as( operator => registry => { action => 'save', content => '<h1>Saved</h1>' } );
    ok !$result->{errors}, 'save is accepted';
    is content_in('registry'), '<h1>Saved</h1>', 'the template is saved';

    # In registry, revert copies registry's own row onto itself: accepted, unchanged.
    $result = edit_as( operator => registry => { action => 'revert' } );
    ok !$result->{errors}, 'revert is accepted';
    is $result->{template_data}{flash}, 'reverted', 'and reports the revert';
};

done_testing;
