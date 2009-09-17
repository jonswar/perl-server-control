package Server::Control::t::Base;
use base qw(Test::Class);
use File::Slurp;
use File::Temp qw(tempfile tempdir);
use Guard;
use HTTP::Server::Simple;
use Log::Any;
use Net::Server;
use POSIX qw(geteuid getegid);
use Proc::ProcessTable;
use Server::Control::Util
  qw(kill_my_children is_port_active something_is_listening_msg);
use Test::Log::Dispatch;
use Test::Most;
use strict;
use warnings;

our @ctls;

# Moved up from Server::Control::t::NetServer::create_ctl because it is used
# in test_port_busy too
sub create_net_server_ctl {
    my ( $self, $port, $temp_dir, %extra_params ) = @_;

    require Server::Control::NetServer;
    return Server::Control::NetServer->new(
        net_server_class  => 'Net::Server::Fork',
        net_server_params => {
            port     => $port,
            pid_file => $temp_dir . "/server.pid",
            log_file => $temp_dir . "/server.log",
            user     => geteuid(),
            group    => getegid()
        },
        %extra_params
    );
}

sub test_startup : Tests(startup) {
    my $self = shift;

    my $parent_pid = $$;
    $self->{stop_guard} = guard( sub { cleanup() if $$ == $parent_pid } );
}

sub test_setup : Tests(setup) {
    my $self = shift;

    # How to pick this w/o possibly conflicting with a port already in use?
    # Might not want to pick from a bunch of ports...if we start
    # accidentally leaving test servers running, it'll just compound the problem
    #
    $self->{port} = 15432;
    if ( is_port_active( $self->{port}, 'localhost' ) ) {
        die something_is_listening_msg( $self->{port}, 'localhost' );
    }
    $self->{temp_dir} =
      tempdir( 'Server-Control-XXXX', DIR => '/tmp', CLEANUP => 1 );
    $self->{log} = Test::Log::Dispatch->new( min_level => 'info' );
    Log::Any->set_adapter( 'Dispatch', dispatcher => $self->{log} );
    $self->{ctl} = $self->create_ctl( $self->{port}, $self->{temp_dir} );
    push( @ctls, $self->{ctl} );
}

sub test_simple : Tests(8) {
    my $self = shift;
    my $ctl  = $self->{ctl};
    my $log  = $self->{log};
    my $port = $self->{port};

    ok( !$ctl->is_running(), "not running" );
    $ctl->stop();
    $log->contains_only_ok( qr/server '.*' is not running/,
        "stop: is not running" );

    $ctl->start();
    $log->contains_ok(qr/waiting for server start/);
    $log->contains_only_ok(qr/is now running.* and listening to port $port/);
    ok( $ctl->is_running(), "is running" );
    $ctl->start();
    $log->contains_only_ok( qr/server '.*' is already running/,
        "start: already running" );

    $ctl->stop();
    $log->contains_ok(qr/stopped/);
    ok( !$ctl->is_running(), "not running" );
}

sub test_port_busy : Tests(3) {
    my $self = shift;
    my $ctl  = $self->{ctl};
    my $log  = $self->{log};
    my $port = $self->{port};

    # Start another server listening on same port
    my $temp_dir2 =
      tempdir( 'Server-Control-XXXX', DIR => '/tmp', CLEANUP => 1 );
    my $ctl2 = $self->create_net_server_ctl( $port, $temp_dir2 );
    $ctl2->start();

    ok( !$ctl->is_running(),  "not running" );
    ok( $ctl->is_listening(), "listening" );
    $ctl->start();
    $log->contains_ok(
        qr/pid file '.*' does not exist, but something.*is listening to localhost:$port/
    );

    $ctl2->stop();
}

sub test_wrong_port : Tests(7) {
    my $self = shift;
    my $ctl  = $self->{ctl};
    my $log  = $self->{log};
    my $port = $self->{port};

    # Tell ctl object to expect wrong port, to simulate a server not starting properly
    my $new_port = $port + 1;
    $ctl->{port}                = $new_port;
    $ctl->{wait_for_start_secs} = 1;
    $ctl->start();
    $log->contains_ok(qr/waiting for server start/);
    $log->contains_ok(
        qr/after .*, server .* is running \(pid .*\), but not listening to port $new_port/
    );
    ok( $ctl->is_running(),    "running" );
    ok( !$ctl->is_listening(), "not listening" );

    $ctl->stop();
    $log->contains_ok(qr/stopped/);
    ok( !$ctl->is_running(), "not running" );
}

sub test_corrupt_pid_file : Test(3) {
    my $self     = shift;
    my $ctl      = $self->{ctl};
    my $log      = $self->{log};
    my $pid_file = $ctl->pid_file;

    write_file( $pid_file, "blah" );
    $ctl->start();
    $log->contains_ok(qr/pid file '.*' does not contain a valid process id/);
    $log->contains_ok(qr/deleting bogus pid file/);
    ok( $ctl->is_running(), "is running" );
    $ctl->stop();
}

sub test_rc_file : Tests(6) {
    my $self = shift;

    my $rc_contents = join( "\n", "bind_addr: 1.2.3.4", "name: foo",
        "wait-for-status-secs: 7" );
    my $temp_dir2 =
      tempdir( 'Server-Control-XXXX', DIR => '/tmp', CLEANUP => 1 );

    my $test_properties = sub {
        my $ctl = shift;
        is( $ctl->bind_addr,            "1.2.3.4", "bind_addr" );
        is( $ctl->name,                 "bar",     "name" );
        is( $ctl->wait_for_status_secs, 7,         "wait_for_status_secs" );
    };

    {
        write_file( $temp_dir2 . "/serverctl.yml", $rc_contents );
        my $ctl = $self->create_ctl(
            $self->{port}, $temp_dir2,
            server_root => $temp_dir2,
            name        => "bar"
        );
        $test_properties->($ctl);
    }

    {
        my $temp_dir3 =
          tempdir( 'Server-Control-XXXX', TMPDIR => 1, CLEANUP => 1 );
        my $rc_file = "$temp_dir3/foo.yml";
        write_file( $rc_file, $rc_contents );
        my $ctl = $self->create_ctl(
            $self->{port}, $temp_dir2,
            serverctlrc => $rc_file,
            name        => "bar"
        );
        $test_properties->($ctl);
    }
}

sub cleanup {
    foreach my $ctl (@ctls) {
        if ( $ctl->is_running() ) {
            $ctl->stop();
        }
    }
    kill_my_children();
}

1;
