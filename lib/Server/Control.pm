package Server::Control;
use Moose;
use Cwd qw(realpath);
use File::Slurp qw(read_file);
use File::Spec::Functions qw(catdir catfile);
use IO::Socket;
use Log::Any qw($log);
use Log::Dispatch::Screen;
use Proc::ProcessTable;
use Server::Control::Util qw(trim dp);
use Time::HiRes qw(usleep);
use strict;
use warnings;

our $VERSION = '0.01';

has 'bind_addr'           => ( is => 'ro', default    => 'localhost' );
has 'description'         => ( is => 'ro', lazy_build => 1 );
has 'error_log'           => ( is => 'ro', lazy_build => 1 );
has 'log_dir'             => ( is => 'ro', lazy_build => 1 );
has 'pid_file'            => ( is => 'ro', lazy_build => 1 );
has 'port'                => ( is => 'ro', required   => 1 );
has 'root_dir'            => ( is => 'ro' );
has 'use_sudo'            => ( is => 'ro', lazy_build => 1 );
has 'wait_for_start_secs' => ( is => 'ro', default    => 10 );
has 'wait_for_stop_secs'  => ( is => 'ro', default    => 10 );

__PACKAGE__->meta->make_immutable();

use constant {
    INACTIVE  => 0,
    RUNNING   => 1,
    LISTENING => 2,
    ACTIVE    => 3,
};

#
# ATTRIBUTE BUILDERS
#

sub _build_description {
    my $self = shift;
    return "server '" . ref($self) . "'";
}

sub _build_error_log {
    my $self = shift;
    return
      defined( $self->log_dir ) ? catdir( $self->log_dir, "error_log" ) : undef;
}

sub _build_log_dir {
    my $self = shift;
    return
      defined( $self->root_dir ) ? catdir( $self->root_dir, "logs" ) : undef;
}

sub _build_pid_file {
    die "cannot determine pid_file";
}

sub _build_use_sudo {
    my $self = shift;
    return $self->port < 1024;
}

#
# PUBLIC METHODS
#

sub handle_cmdline {
    my ( $self, %params ) = @_;

    my $cmd = $params{cmd} || $ARGV[0];
    my $verbose = $params{verbose};

    my $dispatcher = Log::Dispatch->new();
    $dispatcher->add(
        Log::Dispatch::Screen->new(
            name      => 'screen',
            min_level => $verbose ? 'debug' : 'info',
            callbacks => sub { my %params = @_; "$params{message}\n" }
        )
    );
    Log::Any->set_adapter( 'Dispatch', dispatcher => $dispatcher );
    my @valid_commands = $self->_valid_commands;

    if ( defined($cmd) && grep { $_ eq $cmd } @valid_commands ) {
        $self->$cmd();
    }
    else {
        die sprintf( "usage: %s [%s]", $0, join( "|", @valid_commands ) );
    }
}

sub start {
    my $self = shift;

    if ( my $proc = $self->is_running() ) {
        $log->warnf( "%s already running (pid %d)",
            $self->description(), $proc->pid );
        return;
    }
    elsif ( $self->is_listening() ) {
        $log->warnf(
            "cannot start %s - pid file '%s' does not exist, but something is listening to port %d",
            $self->description(), $self->pid_file(), $self->port(),
        );
        return;
    }

    my $error_size_start = $self->_start_error_log_watch();

    eval { $self->do_start() };
    if ( my $err = $@ ) {
        $log->errorf( "error while trying to start %s: %s",
            $self->description(), $err );
        $self->_report_error_log_output($error_size_start);
        return;
    }

    $log->infof("waiting for server start");
    my $wait_until = time() + $self->wait_for_start_secs();
    while ( time < $wait_until ) {
        if ( $self->status == ACTIVE ) {
            ( my $status = $self->status_as_string() ) =~
              s/running/now running/;
            $log->info($status);
            return;
        }
        usleep(100000);
    }

    $log->warnf(
        "after %d secs, %s",
        $self->wait_for_start_secs(),
        $self->status_as_string()
    );
    $self->_report_error_log_output($error_size_start);
}

sub stop {
    my ($self) = @_;

    my $proc = $self->is_running();
    unless ($proc) {
        $log->warn( $self->status_as_string() );
        return;
    }

    my ( $uid, $eid ) = ( $<, $> );
    if ( ( $eid || $uid ) && $proc->uid != $uid && !$self->use_sudo() ) {
        $log->infof(
            "warning: process %d is owned by uid %d ('%s'), different than current user %d ('%s'); may not be able to stop server",
            $proc->pid,
            $proc->uid,
            scalar( getpwuid( $proc->uid ) ),
            $uid,
            scalar( getpwuid($uid) )
        );
    }

    eval { $self->do_stop($proc) };
    if ( my $err = $@ ) {
        $log->errorf( "error while trying to stop %s: %s",
            $self->description(), $err );
        return;
    }

    $log->infof("waiting for server stop");
    my $wait_until = time() + $self->wait_for_stop_secs();
    while ( time < $wait_until ) {
        if ( $self->status == INACTIVE ) {
            $log->infof( "%s has stopped", $self->description() );
            return;
        }
        usleep(100000);
    }

    $log->warnf(
        "after %d secs, %s",
        $self->wait_for_stop_secs(),
        $self->status_as_string()
    );
}

sub restart {
    my ($self) = @_;

    $self->stop();
    if ( $self->is_running() ) {
        $log->infof( "could not stop %s, will not attempt start",
            $self->description() );
    }
    else {
        $self->start();
    }
}

sub ping {
    my ($self) = @_;

    $log->info( $self->status_as_string() );
}

sub do_start {
    die "must be provided by subclass";
}

sub do_stop {
    my ( $self, $proc ) = @_;

    kill 15, $proc->pid;
}

sub status {
    my ($self) = @_;

    return ( $self->is_running() ? RUNNING   : 0 ) |
      ( $self->is_listening()    ? LISTENING : 0 );
}

sub status_as_string {
    my ($self) = @_;

    my $port   = $self->port;
    my $status = $self->status();
    my $msg =
        ( $status == INACTIVE ) ? "not running"
      : ( $status == RUNNING )
      ? sprintf( "running (pid %d), but not listening to port %d",
        $self->is_running->pid, $port )
      : ( $status == LISTENING )
      ? sprintf( "not running, but something is listening to port %d", $port )
      : ( $status == ACTIVE )
      ? sprintf( "running (pid %d) and listening to port %d",
        $self->is_running->pid, $port )
      : die "invalid status: $status";
    return join( " is ", $self->description(), $msg );
}

sub is_running {
    my ($self) = @_;

    my $pid_file = $self->pid_file();
    my $pid_contents = eval { read_file($pid_file) };
    if ($@) {
        $log->debugf( "pid file '%s' does not exist", $pid_file )
          if $log->is_debug;
        return undef;
    }
    else {
        my ($pid) = ( $pid_contents =~ /^\s*(\d+)\s*$/ );
        unless ( defined($pid) ) {
            $log->infof( "pid file '%s' does not contain a valid process id!",
                $pid_file );
            $self->_handle_corrupt_pid_file();
            return undef;
        }

        my $ptable = new Proc::ProcessTable();
        if ( my ($proc) = grep { $_->pid == $pid } @{ $ptable->table } ) {
            $log->debugf( "pid file '%s' exists and has valid pid %d",
                $pid_file, $pid );
            return $proc;
        }
        else {
            $log->infof(
                "pid file '%s' contains a non-existing process id '%d'!",
                $pid_file, $pid );
            $self->_handle_corrupt_pid_file();
            return undef;
        }
    }
}

sub is_listening {
    my ($self) = @_;

    my $is_listening = IO::Socket::INET->new(
        PeerAddr => $self->bind_addr(),
        PeerPort => $self->port()
    ) ? 1 : 0;
    if ( $log->is_debug ) {
        $log->debugf(
            "%s is listening to %s:%d",
            $is_listening ? "something" : "nothing",
            $self->bind_addr(), $self->port()
        );
    }
    return $is_listening;
}

#
# PRIVATE METHODS
#

sub _valid_commands {
    return qw(start stop restart ping);
}

sub _start_error_log_watch {
    my ($self) = @_;

    return defined( $self->error_log ) ? ( -s $self->error_log() || 0 ) : 0;
}

sub _report_error_log_output {
    my ( $self, $error_size_start ) = @_;

    if ( defined( my $error_log = $self->error_log() ) ) {
        if ( -f $error_log ) {
            my ( $fh, $buf );
            my $error_size_end = ( -s $error_log );
            if ( $error_size_end > $error_size_start ) {
                open( $fh, $error_log );
                seek( $fh, $error_size_start, 0 );
                read( $fh, $buf, $error_size_end - $error_size_start );
                $buf =~ s/^(.*)/> $1/mg;
                if ( $buf =~ /\S/ ) {
                    $log->infof( "error log output:\n%s", $buf );
                }
            }
        }
    }
}

sub _handle_corrupt_pid_file {
    my ($self) = @_;

    my $pid_file = $self->pid_file();
    $log->infof( "deleting bogus pid file '%s'", $pid_file );
    unlink $pid_file or die "cannot remove '$pid_file': $!";
}

1;

__END__

=pod

=head1 NAME

Server::Control -- Flexible apachectl style control for servers

=head1 SYNOPSIS

    use Server::Control::Apache;

    my $apache = Server::Control::Apache->new(
        root_dir     => '/my/apache/dir',
        httpd_binary => '/usr/bin/httpd'
    );
    if ( !$apache->is_running() ) {
        $apache->start();
    }

=head1 DESCRIPTION

C<Server::Control> allows you to control servers in the spirit of apachectl,
where a server is any background process which listens to a port and has a pid
file.

C<Server::Control> is designed to be subclassed for different types of server.
For example, L<Server::Control::Simple|Server::Control::Simple> deals with
L<HTTP::Server::Simple|HTTP::Server::Simple> servers, and
L<Server::Control::Apache|Server::Control::Apache> deals with Apache httpd.

=head1 FEATURES

=over

=item *

Checks server status in multiple ways (looking for an active process,
contacting the server's port)

=item *

Tails the error log when server fails to start

=item *

Detects and handles corrupt or out-of-date pid files

=item *

Uses sudo by default when using restricted (< 1024) port

=back

=head1 CONSTRUCTOR

You can pass the following common options to the constructor:

=over

=item bind_addr

At least one address that the server binds to, so that C<Server::Control> can
check it on start/stop. Defaults to C<localhost>. See also L</port>.

=item description

Description of the server to be used in output and logs. A generic default will
be chosen if none is provided.

=item error_log

Location of error log. Defaults to I<log_dir>/error_log if I<log_dir> is
defined, otherwise undef. When a server fails to start, Server::Control
attempts to show recent messages in the error log.

=item log_dir

Location of logs. Defaults to I<root_dir>/logs if I<root_dir> is defined,
otherwise undef.

=item pid_file

Path to pid file.

=item port

At least one port that server will listen to, so that C<Server::Control> can
check it on start/stop. Required. See also L</bind_addr>.

=item root_dir

Root directory of server, for conf files, log files, etc. This will affect
defaults of other options like I<log_dir>.

=item use_sudo

Whether to use 'sudo' when attempting to start and stop server. Defaults to
true if I<port> < 1024, false otherwise.

=item wait_for_start_secs

Number of seconds to wait for server start before reporting error. Defaults to
10.

=item wait_for_stop_secs

Number of seconds to wait for server stop before reporting error. Defaults to
10.

=back

=head1 METHODS

=head2 Action methods

=over

=item start

Start the server. Calls L</do_start> internally.

=item stop

Stop the server. Calls L</do_stop> internally.

=item restart

Restart the server (by stopping it, then starting it).

=item ping

Log the server's status.

=item handle_cmdline ($cmd, $verbose)

Helper method to process a command-line command for a script like apachectl. If
I<$cmd> is one of start, stop, restart, or ping, it will be called on the
object; otherwise, an appropriate usage error will be thrown. This method will
also cause messages to be logged to STDOUT, as is expected for a command-line
script. I<$verbose> is a boolean indicating whether the log level will be set
to 'debug' or 'info'.

=back

=head2 Status methods

=over

=item is_running

If the server appears running (the pid file exists and contains a valid
process), returns a L<Proc::ProcessTable::Process|Proc::ProcessTable::Process>
object representing the process. Otherwise returns undef.

=item is_listening

Returns a boolean indicating whether the server is listening to the address and
port specified in I<bind_addr> and I<port>. This is checked to determine
whether a server start or stop has been successful.

=item status

Returns status of server as an integer. Use the following constants to
interpret status:

=over

=item *

C<Server::Control::RUNNING> - Pid file exists and contains a valid process

=item *

C<Server::Control::LISTENING> - Something is listening to the specified bind
address and port

=item *

C<Server::Control::ACTIVE> - Equal to RUNNING & LISTENING

=item *

C<Server::Control::INACTIVE> - Equal to 0 (neither RUNNING nor LISTENING)

=back

=item status_as_string

Returns status as a human-readable string, e.g. "server 'foo' is not running"

=back

=head1 LOGGING

C<Server::Control> uses L<Log::Any|Log::Any> for logging, so you have control
over where logs will be sent, if anywhere. The exception is L</handle_cmdline>,
which will tell C<Log::Any> to send logs to STDOUT.

=head1 IMPLEMENTING SUBCLASSES

C<Server::Control> uses L<Moose|Moose>, so ideally subclasses will as well. See
L<Server::Control::Apache|Server::Control::Apache> for an example.

=head2 Subclass methods

=over

=item do_start

This actually starts the server - it is called by L</start> and must be defined
by the subclass. Any parameters to L</start> are passed here.

=item do_stop ($proc)

This actually stops the server - it is called by L</stop> and may be defined by
the subclass. By default, it will send a SIGTERM to the process. I<$proc> is a
L<Proc::ProcessTable::Process|Proc::ProcessTable::Process> object representing
the current process, as returned by L</is_running>.

=back

=head1 RELATED MODULES

=over

=item *

L<App::Control|App::Control> - Same basic idea for any application with a pid
file. No features specific to a server listening on a port, and not easily
subclassable, as all commands are handled in a single case statement.

=item *

L<MooseX::Control|MooseX::Control> - A Moose role for controlling applications
with a pid file. Nice extendability. No features specific to a server listening
on a port, and assumes server starts via a command-line (unlike pure-Perl
servers, say). May end up using this role.

=item *

L<Nginx::Control|Nginx::Control>, L<Sphinx::Control|Sphinx::Control>,
L<Lighttpd::Control|Lighttpd::Control> - Modules which use
L<MooseX::Control|MooseX::Control>

=back

=head1 TO DO

=over

=item *

When a port is being listened to unexpectedly, attempt to report which process
is listening (via lsof, fuser, etc.)

=item *

Possibly add pre- and post- start and stop augment hooks like
L<MooseX::Control|MooseX::Control>, though not sure why inner/augment is better
than before/after methods.

=back

=head1 AUTHOR

Jonathan Swartz

=head1 COPYRIGHT & LICENSE

Copyright (C) 2007 Jonathan Swartz, all rights reserved.

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
