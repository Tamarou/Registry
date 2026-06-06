use 5.42.0;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw(done_testing is ok)];
defer { done_testing };

use Mojo::File qw(path);
use Test::Mojo;
use Registry::DAO;
use Test::Registry::DB;
use Test::Registry::Fixtures;

# --- Guard: no controller may use app->dao (the context-dropping footgun) ---
# Check line-by-line, skipping full-line comments, to avoid false positives.
# Include the base Controller.pm (one directory up from Controller/).
my @files = ( path('lib/Registry/Controller.pm'),
              path('lib/Registry/Controller')->list_tree->grep(sub { /\.pm$/ })->each );
my @offenders;
for my $f (@files) {
    for my $line ( split /\n/, $f->slurp ) {
        next if $line =~ /^\s*#/;
        push @offenders, "$f" if $line =~ /\bapp->dao\b/;
    }
}
is "@offenders", '', 'no controller uses app->dao (use $self->dao)';

# --- Contract: $self->dao resolves request tenant, registry without a request ---
my $t_db = Test::Registry::DB->new;
my $dao  = $t_db->db;
$ENV{DB_URL} = $t_db->uri;
my $t = Test::Mojo->new('Registry');

my $tenant = Test::Registry::Fixtures::create_tenant($dao, { name => 'Acc', slug => 'acc1' });
$dao->db->query('SELECT clone_schema(dest_schema => ?)', $tenant->slug);
my $user = $dao->create(User => { username => 'acc_admin', user_type => 'admin' });

my $c = $t->app->build_controller;
$c->req->headers->header('X-As-Tenant' => $tenant->slug);
$c->stash(current_user => { id => $user->id, user_type => 'admin' });
is $c->dao->current_tenant, 'acc1', '$self->dao -> request tenant';

my $bare = $t->app->build_controller; # no request tenant
is $bare->dao->current_tenant, 'registry', '$self->dao -> registry without context';
