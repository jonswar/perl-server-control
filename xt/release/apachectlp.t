#!perl
use Cwd qw(realpath);
use File::Basename;
use Test::More;
use Capture::Tiny qw(tee);
use File::Temp qw(tempdir);
use File::Which;
use IPC::System::Simple qw(run);
use Server::Control::t::Apache;
use Server::Control::Util qw(dp);
use strict;
use warnings;

if ( !scalar( which('httpd') ) ) {
    plan(skip_all => 'no httpd in PATH');
}
plan(tests => 6);

# How to pick this w/o possibly conflicting...
my $port     = 15432;
my $temp_dir = tempdir( 'Server-Control-XXXX', DIR => '/tmp', CLEANUP => 1 );
my $ctl      = Server::Control::t::Apache->create_ctl( $port, $temp_dir );

my $conf_file = $ctl->conf_file;

my $root_dir = dirname(dirname(realpath($0)));

sub try {
    my ( $cmd, $expected, $desc ) = @_;

    my ($output, $error) = tee {
        my $cmd = "$root_dir/bin/apachectlp -f $conf_file -k $cmd";
        run("$root_dir/bin/apachectlp -f $conf_file -k $cmd");
    };
    like( $output, $expected, "$cmd $desc" );
}

try( 'stop',  qr/is not running/,                          'when not running' );
try( 'start', qr/is now running .* and listening to port/, 'when not running' );
try( 'start', qr/already running/,                         'when running' );
try( 'ping',  qr/is running .* and listening to port/,     'when running' );
try( 'stop',  qr/stopped/,                                 'when running' );
try( 'ping',  qr/not running/,                             'when not running' );
