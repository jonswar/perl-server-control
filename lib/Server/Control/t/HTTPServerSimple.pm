package Server::Control::t::HTTPServerSimple;
use base qw(Server::Control::Test::Class);
use Capture::Tiny qw(capture);
use File::Slurp;
use File::Temp qw(tempdir);
use Guard;
use HTTP::Server::Simple;
use Net::Server;
use Proc::ProcessTable;
use POSIX qw(geteuid getegid);
use Server::Control::HTTPServerSimple;
use Test::Log::Dispatch;
use Test::Most;
use strict;
use warnings;

# Automatically reap child processes
$SIG{CHLD} = 'IGNORE';

# How to pick this w/o possibly conflicting...
my $port = 15432;

my $parent_pid = $$;

my $test_server_class = Moose::Meta::Class->create_anon_class(
    superclasses => ['HTTP::Server::Simple'],
    methods      => {
        net_server => sub { 'Net::Server::Fork' }
    },
    cache => 1
)->name;

sub test_setup : Tests(setup) {
    my $self = shift;

    $self->{temp_dir} =
      tempdir( 'Server-Control-XXXX', DIR => '/tmp', CLEANUP => 1 );
    $self->{pid_file} = $self->{temp_dir} . "/server.pid";
    $self->{log_file} = $self->{temp_dir} . "/server.log";
    $self->{ctl}      = Server::Control::HTTPServerSimple->new(
        server_class      => $test_server_class,
        net_server_params => {
            port     => $port,
            pid_file => $self->{pid_file},
            log_file => $self->{log_file},
            user     => geteuid(),
            group    => getegid()
        },
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

    # Fork and start another server listening on same port
    my $child = fork();
    if ( !$child ) {
        Net::Server->run( port => $port, log_file => $self->{log_file} );
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

sub test_wrong_port : Tests(6) {
    my $self = shift;
    my $ctl  = $self->{ctl};
    my $log  = $self->{log};

    # Tell ctl object to expect wrong port, to simulate a server not starting properly
    my $new_port = $port + 1;
    $ctl->server;    # create server object with old port
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

sub test_missing_params : Test(2) {
    my $self = shift;

    throws_ok {
        Server::Control::HTTPServerSimple->new(
            server_class      => $test_server_class,
            net_server_params => { port => $port }
        )->pid_file();
    }
    qr/pid_file must be passed/;
    throws_ok {
        Server::Control::HTTPServerSimple->new(
            server_class      => $test_server_class,
            net_server_params => { pid_file => $self->{pid_file} }
        )->port();
    }
    qr/port must be passed/;
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
