#!/usr/bin/env perl
use 5.40.0;
use lib        qw(lib);
use local::lib qw(local);

use Mojolicious::Commands;

# Start command line interface for application
Mojolicious::Commands->start_app('Registry');
