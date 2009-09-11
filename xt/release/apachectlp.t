#!perl
use Test::More;
use Capture::Tiny qw(tee tee_merged capture_merged);
use File::Temp qw(tempdir);
use File::Which;
use IPC::System::Simple qw(run);
use Server::Control::t::Apache;
use strict;
use warnings;

if ( !scalar( which('httpd') ) ) {
    plan(skip_all => 'no httpd in PATH');
}
plan(tests => 9);

# How to pick this w/o possibly conflicting...
my $port     = 15432;
my $temp_dir = tempdir( 'Server-Control-XXXX', DIR => '/tmp', CLEANUP => 1 );
my $ctl      = Server::Control::t::Apache->create_ctl( $port, $temp_dir );

my $conf_file = $ctl->conf_file;

sub try_error {
    my ( $opts, $expected ) = @_;

    my $output = capture_merged {
        my $full_cmd = "bin/apachectlp $opts";
        system($full_cmd);
    };
    like( $output, $expected, "apachectlp $opts" );
}

try_error("", qr/must specify -k.*Usage:/s);
try_error("-k start", qr/must specify -d or -f.*Usage:/s);
try_error("-k bleah -f $conf_file", qr/bad command 'bleah': must be one of/s);

sub try {
    my ( $cmd, $expected, $desc ) = @_;

    my ($output, $error) = tee {
        my $full_cmd = "bin/apachectlp -f $conf_file -k $cmd";
        run($full_cmd);
    };
    like( $output, $expected, "$cmd $desc" );
}

try( 'stop',  qr/is not running/,                          'when not running' );
try( 'start', qr/is now running .* and listening to port/, 'when not running' );
try( 'start', qr/already running/,                         'when running' );
try( 'ping',  qr/is running .* and listening to port/,     'when running' );
try( 'stop',  qr/stopped/,                                 'when running' );
try( 'ping',  qr/not running/,                             'when not running' );
