package Server::Control;
use Moose;
use Cwd qw(realpath);
use File::Slurp;
use File::Spec::Functions qw(catdir catfile);
use File::Basename;
use IO::Socket;
use IPC::System::Simple qw(run);
use Log::Any qw($log);
use Log::Dispatch::Screen;
use Proc::ProcessTable;
use Server::Control::Util qw(trim);
use Time::HiRes qw(usleep);
use strict;
use warnings;

has 'description'         => ( is => 'ro', lazy_build => 1 );
has 'error_log'           => ( is => 'ro', lazy_build => 1 );
has 'log_dir'             => ( is => 'ro', lazy_build => 1 );
has 'pid_file'            => ( is => 'ro', lazy_build => 1 );
has 'port'                => ( is => 'ro', required   => 1 );
has 'root_dir'            => ( is => 'ro' );
has 'use_sudo'            => ( is => 'ro', lazy_build => 1 );
has 'wait_for_start_secs' => ( is => 'ro', default    => 5 );
has 'wait_for_stop_secs'  => ( is => 'ro', default    => 5 );

__PACKAGE__->meta->make_immutable();

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
    my $self = shift;
    die "no pid_file and cannot determine log_dir";
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
    Log::Any->set_adapter( 'Log::Dispatch', dispatcher => $dispatcher );
    my @valid_commands = $self->_valid_commands;

    if ( defined($cmd) && grep { $_ eq $cmd } @valid_commands ) {
        $self->$cmd();
    }
    else {
        die sprintf( "usage: %s [%s]", $0, join( "|", @valid_commands ) );
    }
}

sub start {
    my ($self) = @_;

    return unless $self->_assert_not_running();

    if ( $self->_is_port_active() ) {
        $log->infof(
            "pid file '%s' does not exist, but something is listening to port %d (another server?)",
            $self->pid_file(), $self->port()
        );
        $log->infof( "cannot start %s", $self->description() );
        return;
    }

    my $error_size_start = $self->_start_error_log_watch();

    eval { $self->do_start() };
    if ( my $err = $@ ) {
        $log->infof( "%s could not be started: %s", $self->description(),
            $err );
        $self->_report_error_log_output($error_size_start);
        return;
    }

    $log->infof("waiting for server start");
    for ( my $i = 0 ; $i < $self->wait_for_start_secs() * 10 ; $i++ ) {
        last if $self->is_running();
        usleep(100000);
    }

    if ( my $proc = $self->is_running() ) {
        $log->infof( "%s is now running (pid %d) - listening on port %d",
            $self->description, $proc->pid, $self->port );
    }
    else {
        $log->infof( "%s still does not appear to be running after %d secs",
            $self->description(), $self->wait_for_start_secs() );
        $self->_report_error_log_output($error_size_start);
    }
}

sub stop {
    my ($self) = @_;

    my $proc = $self->is_running();
    unless ($proc) {
        $log->infof( "%s not running", $self->description() );
        return;
    }
    my $pid = $proc->pid;

    my ( $uid, $eid ) = ( $<, $> );
    if ( ( $eid || $uid ) && $proc->uid != $uid && !$self->use_sudo() ) {
        $log->infof(
            "warning: process %d is owned by uid %d ('%s'), different than current user %d ('%s'); may not be able to stop server",
            $pid,
            $proc->uid,
            scalar( getpwuid( $proc->uid ) ),
            $uid,
            scalar( getpwuid($uid) )
        );
    }

    unless ( $self->do_stop($proc) ) {
        $log->infof( "%s could not be stopped", $self->description() );
    }
    for ( my $i = 0 ; $i < $self->wait_for_stop_secs() ; $i++ ) {
        usleep(100000);
        $proc = $self->is_running();
        if ($proc) {
            $log->debug("pid file still exists");
        }
        elsif ( $self->_is_port_active() ) {
            $log->debug("port is still active");
        }
        else {
            last;
        }
    }
    if ( my $proc = $self->is_running() ) {
        $log->infof(
            "%s (pid %d) could not could not be stopped gracefully - try again or use 'kill'",
            $self->description(), $pid
        );
    }
    elsif ( $self->_is_port_active() ) {
        $log->infof(
            "%s stopped, but something (possibly process %d or a child) is still listening to port %d",
            $self->description(), $pid, $self->port()
        );
    }
    else {
        $log->infof( "%s stopped", $self->description() );
    }
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

    $log->infof( "%s", $self->status_as_string() );
}

sub do_stop {
    my ( $self, $proc ) = @_;

    kill 15, $proc->pid;
}

sub status_as_string {
    my ($self) = @_;

    if ( my $proc = $self->is_running() ) {
        return
          sprintf( "%s is running (pid %d)", $self->description(), $proc->pid );
    }
    else {
        return sprintf( "%s is not running", $self->description() );
    }
}

sub is_running {
    my ($self) = @_;

    my $pid_file = $self->pid_file();
    if ( -e $pid_file ) {
        my $pid = $self->_read_pid_file($pid_file);
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
    else {
        $log->debugf( "pid file '%s' does not exist", $pid_file )
          if $log->is_debug;
        return undef;
    }
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
                $buf =~ s/^(.)/> $1/mg;
                if ( $buf =~ /\S/ ) {
                    $log->infof( "error log output:\n%s", $buf );
                }
            }
        }
    }
}

sub _assert_running {
    my ($self) = @_;

    if ( $self->is_running() ) {
        return 1;
    }
    else {
        $log->infof( "%s not running", $self->description() );
        return 0;
    }
}

sub _assert_not_running {
    my ($self) = @_;

    my $proc = $self->is_running();
    if ( !$proc ) {
        return 1;
    }
    else {
        $log->infof( "%s already running (pid %d)",
            $self->description(), $proc->pid );
        return 0;
    }
}

sub _handle_corrupt_pid_file {
    my ($self) = @_;

    my $pid_file = $self->pid_file();
    $log->infof( "deleting bogus pid file '%s'", $pid_file );
    unlink $pid_file;
}

sub _is_port_active {
    my ($self) = @_;

    return IO::Socket::INET->new(
        PeerAddr => "localhost",
        PeerPort => $self->port()
    ) ? 1 : 0;
}

sub _read_pid_file {
    my ( $self, $pid_file ) = @_;

    my $pid = trim( read_file($pid_file) );
    return $pid =~ /^\d+$/ ? $pid : undef;
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

Server::Control allows you to control servers in the spirit of apachectl. For
purposes of this module, a server is defined as a background process which has
a pid file and listens to a port.

Server::Control is designed to be subclassed for each type of server. For
example, Server::Control::Apache is a subclass that deals with Apache httpd.
Subclasses are available in separate distributions.

=head1 CONSTRUCTOR

You can pass the following common options to the constructor:

=over

=item description

Description of the server to be used in output and logs. A generic default will
be chosen if none is provided.

=item error_log

Location of error log. Defaults to I<log_dir>/error_log if I<log_dir> is
defined, otherwise undef.

=item log_dir

Location of logs. Defaults to I<root_dir>/logs if I<root_dir> is defined,
otherwise undef.

=item pid_file

Path to pid file.

=item port

At least one port that server will listen to, so that Server::Control can check
it on start/stop. Required.

=item root_dir

Root directory of server, for conf files, log files, etc. This will affect
defaults of other options like I<log_dir>.

=item use_sudo

Whether to use 'sudo' when attempting to start and stop server. Defaults to
true if I<port> < 1024, false otherwise.

=item wait_for_start_secs

Number of seconds to wait for server start before reporting error. Defaults to
5.

=item wait_for_stop_secs

Number of seconds to wait for server stop before reporting error. Defaults to
5.

=back

=head1 METHODS

=over

=item start

Start the server. Calls L</do_start> internally.

=item stop

Stop the server. Calls L</do_stop>

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
by the subclass.

=item do_stop

This actually stops the server - it is called by L</stop> and may be defined by
the subclass. By default, it will send a SIGTERM to the process.

=back

=head1

=head1 SEE ALSO

=head1 AUTHOR

Jonathan Swartz

=head1 COPYRIGHT & LICENSE

Copyright (C) 2007 Jonathan Swartz, all rights reserved.

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
