package Server::Control::Test::Server::Simple;
use base qw(HTTP::Server::Simple);
use strict;
use warnings;

sub net_server { 'Net::Server::Single' }

1;
