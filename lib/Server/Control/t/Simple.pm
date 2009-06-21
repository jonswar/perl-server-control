package Server::Control::t::Simple;
use base qw(Server::Control::Test::Class);
use File::Spec::Functions qw(tmpdir);
use File::Temp qw(tempfile tempdir);
use Guard;
use HTTP::Server::Simple;
use Proc::ProcessTable;
use Server::Control::Simple;
use Server::Control::Util;
use Server::Control::Test::Testable;
use Test::Most;
use strict;
use warnings;

# Automatically reap child processes
$SIG{CHLD} = 'IGNORE';

# How to pick this w/o possibly conflicting...
my $port = 15432;

sub test_setup : Tests(setup) {
    my $self = shift;

    $self->{server} = HTTP::Server::Simple->new($port);
    $self->{pid_file} =
      tempdir( 'Server-Control-XXXX', TMPDIR => 1, CLEANUP => 1 )
      . "/server.pid";
    $self->{ctl} = Server::Control::Simple->new(
        server   => $self->{server},
        pid_file => $self->{pid_file},
    );
    Server::Control::Test::Testable->meta->apply( $self->{ctl} );
    $self->{stop_guard} = guard( \&kill_my_children );
}

sub test_simple : Tests(12) {
    my $self = shift;

    my $ctl = $self->{ctl};
    ok( !$ctl->is_running(), "not running" );
    $ctl->stop();
    $ctl->output_contains_only( qr/server '.*' not running/,
        "stop: is not running" );
    $ctl->output_is_empty();

    $ctl->start();
    $ctl->output_contains(qr/waiting for server start/);
    $ctl->output_contains_only(qr/is now running.* - listening on port $port/);
    ok( $ctl->is_running(), "is running" );
    $ctl->start();
    $ctl->output_contains_only( qr/server '.*' already running/,
        "start: already running" );

    $ctl->stop();
    $ctl->output_contains(qr/stopped/);
    ok( !$ctl->is_running(), "not running" );
}

sub test_port_busy : Tests(2) {
    my $self = shift;
    
    my $other_server = HTTP::Server::Simple->new($port);
    my $other_pid = $other_server->background;
    
    my $ctl = $self->{ctl};
    ok( !$ctl->is_running(), "not running" );
    $ctl->start();
    $ctl->output_contains(qr/pid file '.*' does not exist, but something is listening to port $port/);
}

sub test_no_pid_file_specified : Test(1) {
    my $self = shift;

    throws_ok {
        Server::Control::Simple->new( server => $self->{server} )->pid_file;
    }
    qr/no pid_file/;
}

# Probably a better way to do this on cpan...
sub kill_my_children {
    my $self = shift;

    my $t              = new Proc::ProcessTable;
    my $get_child_pids = sub {
        map { $_->pid } grep { $_->ppid == $$ } @{ $t->table };
    };
    my $send_signal = sub {
        my ($signal, $pids) = @_;
        explain( "sending signal $signal to " . join( ", ", @$pids ) . "\n" );
        kill $signal, @$pids;
    };

    if ( my @child_pids = $get_child_pids->() ) {
        $send_signal->(15, \@child_pids);
        for ( my $i = 0 ; $i < 3 && $get_child_pids->() ; $i++ ) {
            sleep(1);
        }
        if ( @child_pids = $get_child_pids->() ) {
            $send_signal->(9, \@child_pids);
        }
    }
}

1;
