package Server::Control::t::Apache;
use base qw(Server::Control::t::Base);
use Cwd qw(realpath);
use File::Basename;
use File::Path;
use File::Slurp qw(write_file);
use File::Which;
use POSIX qw(geteuid getegid);
use Server::Control::Apache;
use Test::Most;
use strict;
use warnings;

sub check_httpd_binary : Test(startup) {
    my $self = shift;

    if ( !scalar( which('httpd') ) ) {
        $self->SKIP_ALL("cannot find httpd in path");
    }
}

sub create_ctl {
    my ( $self, $port, $temp_dir, %extra_params ) = @_;

    mkpath( "$temp_dir/logs", 0, 0775 );
    mkpath( "$temp_dir/conf", 0, 0775 );
    my $conf = "
        ServerName mysite.com
        ServerRoot $temp_dir
        Listen     $port
        PidFile    $temp_dir/logs/my-httpd.pid
        LockFile   $temp_dir/logs/accept.lock
        ErrorLog   $temp_dir/logs/my-error.log
        StartServers 2
        MinSpareServers 1
        MaxSpareServers 2
    ";
    write_file( "$temp_dir/conf/httpd.conf", $conf );
    return Server::Control::Apache->new(
        server_root => $temp_dir,
        %extra_params
    );
}

sub test_build_default : Test(6) {
    my $self = shift;

    my $ctl      = $self->{ctl};
    my $temp_dir = $self->{temp_dir};
    is_realpath( $ctl->conf_file, "$temp_dir/conf/httpd.conf",
        "determined conf_file from server root" );
    is( $ctl->bind_addr, "localhost",   "determined bind_addr from default" );
    is( $ctl->port,      $self->{port}, "determined port from conf file" );
    is(
        $ctl->description,
        sprintf( "server '%s'", basename($temp_dir) ),
        "determine description from server root"
    );
    is_realpath( $ctl->pid_file, "$temp_dir/logs/my-httpd.pid",
        "determined pid_file from conf file" );
    like(
        $ctl->error_log,
        qr{$temp_dir/logs/my-error.log},
        "determined error_log from conf file"
    );
}

sub test_build_alternate : Test(6) {
    my $self = shift;

    my $temp_dir = $self->{temp_dir} . "/alternate";
    mkpath( "$temp_dir/conf", 0, 0775 );
    my $port = $self->{port} + 1;
    my $conf = "
        ServerRoot $temp_dir
        Listen 1.2.3.4:$port
    ";
    my $conf_file = "$temp_dir/conf/httpd.conf";
    write_file( $conf_file, $conf );
    my $ctl =
      Server::Control::Apache->new( conf_file => $conf_file, name => 'foo' );
    is( $ctl->server_root, $temp_dir, "determined server_root from conf file" );
    is( $ctl->bind_addr,   "1.2.3.4", "determined bind_addr from conf file" );
    is( $ctl->port,        $port,     "determined port from conf file" );
    is( $ctl->pid_file, "$temp_dir/logs/httpd.pid",
        "determined pid_file from default" );
    is( $ctl->description, "server 'foo'",
        "determined description from argument" );
    like( $ctl->error_log, qr{$temp_dir/logs/error.log},
        "determined error_log from default" );
}

sub test_missing_params : Test(1) {
    my $self = shift;
    my $port = $self->{port};

    throws_ok {
        Server::Control::Apache->new(
            port     => $self->{port},
            pid_file => $self->{temp_dir} . "/logs/httpd.pid"
        )->conf_file();
    }
    qr/no conf_file or server_root specified/;
}

sub test_graceful_stop : Tests(5) {
    my $self = shift;
    my $ctl  = $self->{ctl};
    my $log  = $self->{log};

    ok( !$ctl->is_running(), "not running" );
    $ctl->start();
    ok( $ctl->is_running(), "is running" );
    $ctl->graceful_stop();
    $log->contains_ok(qr/stopped/);
    ok( !$ctl->is_running(), "not running" );
    is( $ctl->stop_cmd(), 'graceful-stop' );
}

sub test_graceful_restart : Tests(6) {
    my $self = shift;
    my $ctl  = $self->{ctl};

    $self->setup_test_logger('debug');
    my $log = $self->{log};

    ok( !$ctl->is_running(), "not running" );
    $ctl->start();
    ok( $ctl->is_running(), "is running" );
    $log->clear();
    $ctl->graceful();
    $log->contains_ok(qr/running '.*-k graceful.*'/);
    $log->contains_ok(qr/waiting for server graceful restart/);
    ok( $ctl->is_running(), "is running" );
    $ctl->stop();
    ok( !$ctl->is_running(), "is not running" );
}

sub is_realpath {
    my ( $path1, $path2, $name ) = @_;

    is( realpath($path1), realpath($path2), $name );
}

1;
