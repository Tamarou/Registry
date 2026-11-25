#!/usr/bin/env perl
# ABOUTME: Who may run a workflow is data on its row: roles or the public mark import from YAML and round-trip.
# ABOUTME: Covers copy_workflow into tenant schemas, the backfill from the old %ROLES map, and every refusal.
use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use YAML::XS qw(Load);
no warnings 'experimental::builtin';

use Registry::DAO;
use Test::Registry::DB;
use Test::Registry::Mojo;
use Mojo::Home;
use Mojo::Pg;
use App::Sqitch;
use Test::PostgreSQL;
use File::Temp;
use Mojo::File;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

sub workflow_yaml ( $slug, $head = '' ) {
    return "name: $slug\nslug: $slug\ndescription: fixture\n$head"
      . "steps:\n  - slug: only\n    description: x\n";
}

sub row ( $slug, $schema = 'registry' ) {
    $dao->db->query( qq{SELECT roles, public FROM "$schema".workflows WHERE slug = ?}, $slug )->hash;
}

subtest 'roles import onto the row and round-trip through to_yaml' => sub {
    my $workflow = Registry::DAO::Workflow->from_yaml( $dao,
        workflow_yaml( 'roles-flow', "roles:\n  - admin\n  - staff\n" ) );
    is_deeply row('roles-flow'), { roles => [qw(admin staff)], public => 0 }, 'the row holds the roles';
    is_deeply $workflow->roles, [qw(admin staff)], 'and the object reads them';

    my $back = Load( $workflow->to_yaml($dao) );
    is_deeply $back->{roles}, [qw(admin staff)], 'to_yaml emits the roles';
    ok !exists $back->{public}, 'and no public mark';
};

subtest 'the public mark imports with no roles and round-trips' => sub {
    my $workflow =
      Registry::DAO::Workflow->from_yaml( $dao, workflow_yaml( 'public-flow', "public: true\n" ) );
    is_deeply row('public-flow'), { roles => undef, public => 1 }, 'the row is public with no roles';

    my $back = Load( $workflow->to_yaml($dao) );
    ok builtin::is_bool( $back->{public} ) && $back->{public}, 'to_yaml emits public: true';
    ok !exists $back->{roles}, 'and no roles';
};

subtest 'copy_workflow carries roles and the public mark into a tenant schema' => sub {
    my $db = $dao->db;
    $db->query( 'INSERT INTO registry.tenants (name, slug) VALUES (?, ?)', 'Copy Target', 'copytarget' );
    $db->query( 'SELECT registry.clone_schema(?)', 'copytarget' );
    for my $slug (qw(roles-flow public-flow)) {
        my $id = $db->query( 'SELECT id FROM registry.workflows WHERE slug = ?', $slug )->array->[0];
        $db->query( 'SELECT registry.copy_workflow(?, ?)', 'copytarget', $id );
        is_deeply row( $slug, 'copytarget' ), row($slug), "$slug keeps its entry in the tenant's copy";
    }
};

# Each refusal goes through import_workflows, the path every import takes, so
# the error it reports is the one an operator reads.
sub import_one ( $slug, $head ) {
    my $dir  = File::Temp->newdir;
    my $file = Mojo::File->new("$dir/$slug.yml");
    $file->spew( workflow_yaml( $slug, $head ) );
    return ( $dao->import_workflows( [$file] ) // '', "$file" );
}

sub refused ( $slug, $head, $why ) {
    my ( $output, $file ) = import_one( $slug, $head );
    like $output, qr/Error importing workflow \Q$file\E: .*$why/, "$slug is refused naming $file";
    ok !row($slug), "and $slug stores no row";
}

subtest 'roles and public mark together rejected' => sub {
    refused( 'both-flow', "public: true\nroles: [admin]\n", 'both roles and the public mark' );
};

subtest 'unknown role name rejected' => sub {
    refused( 'typo-flow',  "roles: [admn]\n",              'unknown role admn' );
    refused( 'super-flow', "roles: [admin, superadmin]\n", 'unknown role superadmin' );
};

subtest 'empty roles list rejected' => sub {
    refused( 'empty-flow', "roles: []\n", 'roles must be a non-empty list' );
};

subtest 'non list roles rejected' => sub {
    refused( 'scalar-flow', "roles: admin\n",            'roles must be a non-empty list' );
    refused( 'hash-flow',   "roles:\n  admin: true\n",   'roles must be a non-empty list' );
};

subtest 'falsy public mark is not public' => sub {
    my %not_the_mark = ( 'zero-flow' => '0', 'no-flow' => 'no', 'string-flow' => '"false"' );
    for my $slug ( sort keys %not_the_mark ) {
        import_one( $slug, "public: $not_the_mark{$slug}\n" );
        is row($slug)->{public}, 0, "public: $not_the_mark{$slug} does not mark $slug public";
    }
};

# The map this data replaces. Every entry must carry over exactly.
$ENV{DB_URL} = $test_db->uri;
my $app = Test::Registry::Mojo->new('Registry')->app;

subtest 'every shipped workflow imports with the roles the map gives it, or the public mark' => sub {
    my @files = grep { !Load( $_->slurp )->{draft} }
      Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml\z/)->each;
    ok @files, 'there are shipped workflows';
    $dao->import_workflows( \@files );

    for my $file (@files) {
        my $slug = Load( $file->slurp )->{slug};
        my $got  = row($slug) or do { fail "$slug imported"; next };
        if ( my $roles = $app->workflow_roles($slug) ) {
            is_deeply $got, { roles => $roles, public => 0 }, "$slug has exactly the map's roles";
        }
        else {
            is_deeply $got, { roles => undef, public => 1 }, "$slug, with no map entry, is public";
        }
    }
};


# The backfill, on rows that existed before the migration: its own database,
# deployed to the parent change, so the rows are written without the columns.
{
    my $change = 'workflow-roles-data';
    my $pg     = Test::PostgreSQL->new or BAIL_OUT $Test::PostgreSQL::errstr;
    my $sqitch = App::Sqitch->new;
    $sqitch->run( 'sqitch', 'deploy', '-t', $pg->uri, '--to', "$change^" );
    my $db = Mojo::Pg->new( $pg->uri )->db;
    $db->query( 'INSERT INTO registry.tenants (name, slug) VALUES (?, ?)', 'Backfill', 'backfilled' );
    $db->query( 'SELECT registry.clone_schema(?)', 'backfilled' );
    # Every shipped slug, drafts too, so the migration's copy of the map is
    # compared with %ROLES entry for entry.
    my %public = map { my $y = Load( $_->slurp ); ( $y->{slug} => !!$y->{public} ) }
      Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml\z/)->each;
    for my $schema (qw(registry backfilled)) {
        $db->query( qq{INSERT INTO "$schema".workflows (name, slug) VALUES (?, ?)}, $_, $_ )
          for sort( keys %public ), 'unlisted-flow';
    }
    $sqitch->run( 'sqitch', 'deploy', '-t', $pg->uri, '--to', $change );

    my $entry = sub ( $schema, $slug ) {
        $db->query( qq{SELECT roles, public FROM "$schema".workflows WHERE slug = ?}, $slug )->hash;
    };

    subtest 'backfill gives existing rows the map roles and the public mark' => sub {
        for my $schema (qw(registry backfilled)) {
            for my $slug ( sort keys %public ) {
                is_deeply $entry->( $schema, $slug ),
                  { roles => $app->workflow_roles($slug), public => $public{$slug} ? 1 : 0 },
                  "$schema.$slug matches the map and its YAML";
            }
        }
    };

    subtest 'backfill does not public mark unlisted slugs' => sub {
        is_deeply $entry->( $_, 'unlisted-flow' ), { roles => undef, public => 0 },
          "$_.unlisted-flow has no entry" for qw(registry backfilled);
    };
}

done_testing;
