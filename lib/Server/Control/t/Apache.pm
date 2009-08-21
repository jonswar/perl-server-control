package Server::Control::t::Apache;
use base qw(Server::Control::t::Base);
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
    my $self = shift;

    my $temp_dir = $self->{temp_dir};
    my $port     = $self->{port};
    mkpath( "$temp_dir/logs", 0, 0775 );
    mkpath( "$temp_dir/conf", 0, 0775 );
    my $conf = "
        ServerRoot $temp_dir
        Listen     localhost:$port
        PidFile    $temp_dir/logs/httpd.pid
        LockFile   $temp_dir/logs/accept.lock
        StartServers 2
        MinSpareServers 1
        MaxSpareServers 2
    ";
    write_file( "$temp_dir/conf/httpd.conf", $conf );
    return Server::Control::Apache->new(
        root_dir => $self->{temp_dir},
        port     => $self->{port}
    );
}

sub test_missing_params : Test(2) {
    my $self = shift;
    my $port = $self->{port};

    throws_ok {
        Server::Control::Apache->new(
            port     => $self->{port},
            pid_file => $self->{temp_dir} . "/logs/httpd.pid"
        )->conf_file();
    }
    qr/no conf_file specified and cannot determine conf_dir/;
    throws_ok {
        Server::Control::Apache->new(
            port      => $self->{port},
            conf_file => $self->{temp_dir} . "/conf/httpd.conf"
        )->pid_file();
    }
    qr/no pid_file specified and cannot determine log_dir/;
}

1;
