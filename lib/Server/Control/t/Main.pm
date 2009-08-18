package Server::Control::t::Main;
use base qw(Server::Control::Test::Class);
use Capture::Tiny qw(capture);
use File::Slurp;
use File::Temp qw(tempdir);
use Guard;
use Proc::ProcessTable;
use POSIX qw(geteuid getegid);
use Server::Control::Simple;
use Server::Control::Test::Server::Simple;
use Test::Log::Dispatch;
use Test::Most;
use strict;
use warnings;

# Automatically reap child processes
$SIG{CHLD} = 'IGNORE';

# How to pick this w/o possibly conflicting...
my $port = 15432;

my $parent_pid = $$;

sub test_setup : Tests(setup) {
    my $self = shift;

    $self->{server} = Server::Control::Test::Server::Simple->new($port);
    $self->{pid_file} =
      tempdir( 'Server-Control-XXXX', TMPDIR => 1, CLEANUP => 1 )
      . "/server.pid";
    $self->{ctl} = Server::Control::Simple->new(
        server     => $self->{server},
        pid_file   => $self->{pid_file},
        run_params => { user => geteuid(), group => getegid(), setsid => 1 },
    );
    $self->{log} = Test::Log::Dispatch->new( min_level => 'info' );
    Log::Any->set_adapter( 'Dispatch', dispatcher => $self->{log} );
    $self->{stop_guard} =
      guard( sub { kill_my_children() if $$ == $parent_pid } );
}

sub test_simple : Tests(8) {
    my $self = shift;
    my $ctl  = $self->{ctl};
    my $log  = $self->{log};

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

    my $other_server;
    capture {    # Discard stdout banner
        $other_server = HTTP::Server::Simple->new($port);
        $other_server->background;
    };
    sleep(1);

    ok( !$ctl->is_running(),  "not running" );
    ok( $ctl->is_listening(), "listening" );
    $ctl->start();
    $log->contains_ok(
        qr/pid file '.*' does not exist, but something is listening to port $port/
    );
}

sub test_wrong_port : Tests(6) {
    my $self = shift;
    my $ctl  = $self->{ctl};
    my $log  = $self->{log};

    # Tell ctl object to expect wrong port, to simulate a server not starting properly
    my $new_port = $port + 1;
    $ctl->{port}                = $new_port;
    $ctl->{wait_for_start_secs} = 1;
    $ctl->start();
    $log->contains_ok(qr/waiting for server start/);
    $log->contains_only_ok(
        qr/after .*, server .* is running \(pid .*\), but not listening to port $new_port/
    );
    ok( $ctl->is_running(),    "running" );
    ok( !$ctl->is_listening(), "not listening" );

    $ctl->stop();
    $log->contains_ok(qr/stopped/);
    ok( !$ctl->is_running(), "not running" );
}

sub test_no_pid_file_specified : Test(1) {
    my $self = shift;

    throws_ok {
        Server::Control::Simple->new( server => $self->{server} )->pid_file;
    }
    qr/pid_file must be provided/;
}

sub test_corrupt_pid_file : Test(3) {
    my $self     = shift;
    my $ctl      = $self->{ctl};
    my $log      = $self->{log};
    my $pid_file = $self->{pid_file};

    write_file( $pid_file, "blah" );
    $ctl->start();
    $log->contains_ok(qr/pid file '.*' does not contain a valid process id/);
    $log->contains_ok(qr/deleting bogus pid file/);
    ok( $ctl->is_running(), "is running" );
    $ctl->stop();
}

# Probably a better way to do this on cpan...
sub kill_my_children {
    my $self = shift;

    my $t              = new Proc::ProcessTable;
    my $get_child_pids = sub {
        map { $_->pid } grep { $_->ppid == $$ } @{ $t->table };
    };
    my $send_signal = sub {
        my ( $signal, $pids ) = @_;
        explain( "sending signal $signal to " . join( ", ", @$pids ) . "\n" );
        kill $signal, @$pids;
    };

    if ( my @child_pids = $get_child_pids->() ) {
        $send_signal->( 15, \@child_pids );
        for ( my $i = 0 ; $i < 3 && $get_child_pids->() ; $i++ ) {
            sleep(1);
        }
        if ( @child_pids = $get_child_pids->() ) {
            $send_signal->( 9, \@child_pids );
        }
    }
}

1;
