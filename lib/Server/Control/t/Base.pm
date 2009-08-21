package Server::Control::t::Base;
use base qw(Server::Control::Test::Class);
use Capture::Tiny qw(capture);
use File::Slurp;
use File::Temp qw(tempdir);
use Guard;
use HTTP::Server::Simple;
use Log::Any;
use Net::Server;
use Proc::Killfam;
use Proc::ProcessTable;
use Test::Log::Dispatch;
use Test::Most;
use strict;
use warnings;

our @ctls;

sub test_startup : Tests(startup) {
    my $self = shift;

    my $parent_pid = $$;
    $self->{stop_guard} = guard( sub { cleanup() if $$ == $parent_pid } );
}

sub test_setup : Tests(setup) {
    my $self = shift;

    # How to pick this w/o possibly conflicting...
    $self->{port} = 15432;
    $self->{temp_dir} =
      tempdir( 'Server-Control-XXXX', DIR => '/tmp', CLEANUP => 0 );
    $self->{log} = Test::Log::Dispatch->new( min_level => 'info' );
    Log::Any->set_adapter( 'Dispatch', dispatcher => $self->{log} );
    $self->{ctl} = $self->create_ctl();
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
    $log->contains_only_ok( qr/server '.*' already running/,
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

    # Fork and start another server listening on same port
    my $child = fork();
    if ( !$child ) {
        Net::Server->run( port => $port, log_file => $ctl->error_log );
        exit;
    }
    sleep(1);

    ok( !$ctl->is_running(),  "not running" );
    ok( $ctl->is_listening(), "listening" );
    $ctl->start();
    $log->contains_ok(
        qr/pid file '.*' does not exist, but something is listening to port $port/
    );
    kill 15, $child;
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

# NOTE: Doesn't work with apache and other servers that end up with ppid=1
sub kill_my_children {
    my $self = shift;

    foreach my $signal ( 15, 9 ) {
        my $pt = new Proc::ProcessTable;
        if ( my @child_pids = Proc::Killfam::get_pids( $pt->table, $$ ) ) {
            explain("sending signal $signal to "
                  . join( ", ", @child_pids )
                  . "\n" );
            Proc::Killfam::killfam( $signal, \@child_pids );
            sleep(1);
        }
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
