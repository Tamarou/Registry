#!/usr/bin/env perl
use 5.38.2;
use lib qw(lib);

use Mojolicious::Commands;

# Start command line interface for application
Mojolicious::Commands->start_app('Registry');
