#!perl
use Test::More;
use Capture::Tiny qw(tee tee_merged capture_merged);
use File::Temp qw(tempdir);
use File::Which;
use IPC::System::Simple qw(run);
use Server::Control::Util qw(kill_my_children);
use Server::Control::t::Apache;
use strict;
use warnings;

if ( !scalar( which('httpd') ) ) {
    plan( skip_all => 'no httpd in PATH' );
}
plan( tests => 10 );

# How to pick this w/o possibly conflicting...
my $port     = 15432;
my $temp_dir = tempdir( 'Server-Control-XXXX', DIR => '/tmp', CLEANUP => 1 );
my $ctl      = Server::Control::t::Apache->create_ctl( $port, $temp_dir );

sub try {
    my ( $opts, $expected, $desc ) = @_;

    my ( $output, $error ) = tee {
        my $full_cmd = "bin/apachectlp $opts";
        run($full_cmd);
    };
    like( $output, $expected, "$opts $desc" );
}

sub try_error {
    my ( $opts, $expected ) = @_;

    my $output = capture_merged {
        my $full_cmd = "bin/apachectlp $opts";
        system($full_cmd);
    };
    like( $output, $expected, "apachectlp $opts" );
}

eval {
    my $conf_file = $ctl->conf_file;

    try( "-f $conf_file -k stop", qr/is not running/, 'when not running' );
    try(
        "-d $temp_dir -k start",
        qr/is now running .* and listening to port/,
        'when not running'
    );
    try( "-f $conf_file -k start", qr/already running/, 'when running' );
    try(
        "-d $temp_dir -k ping",
        qr/is running .* and listening to port/,
        'when running'
    );

    try(
        "-f $conf_file -k ping --name foo --pid-file $temp_dir/logs/my-httpd.pid --port $port",
        qr/server 'foo' is running .* and listening to port/,
        'ping when running, specify name, pid file and port on command line'
    );

    try( "-d $temp_dir -k stop",  qr/stopped/,     'when running' );
    try( "-f $conf_file -k ping", qr/not running/, 'when not running' );

    try_error( "",         qr/must specify -k.*Usage:/s );
    try_error( "-k start", qr/must specify -d or -f.*Usage:/s );
    try_error( "-k bleah -f $conf_file",
        qr/bad command 'bleah': must be one of/s );
};
my $error = $@;
cleanup();
die $error if $error;

sub cleanup {
    eval { $ctl->stop() };
    kill_my_children();
}
