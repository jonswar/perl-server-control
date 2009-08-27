package Server::Control;
use File::Basename;
use File::Slurp qw(read_file);
use File::Spec::Functions qw(catdir);
use IPC::System::Simple qw();
use Log::Any qw($log);
use Log::Dispatch::Screen;
use Moose;
use Proc::ProcessTable;
use Time::HiRes qw(usleep);
use Server::Control::Util qw(is_port_active something_is_listening_msg);
use strict;
use warnings;

our $VERSION = '0.05';

# Note: In some cases we use lazy_build rather than specifying required or a
# default, to make life easier for subclasses.
#
has 'bind_addr'            => ( is => 'ro', lazy_build => 1 );
has 'description'          => ( is => 'ro', lazy_build => 1 );
has 'error_log'            => ( is => 'ro', lazy_build => 1 );
has 'log_dir'              => ( is => 'ro', lazy_build => 1 );
has 'pid_file'             => ( is => 'ro', lazy_build => 1 );
has 'poll_for_status_secs' => ( is => 'ro', default    => 0.2 );
has 'port'                 => ( is => 'ro', lazy_build => 1 );
has 'root_dir'             => ( is => 'ro' );
has 'use_sudo'             => ( is => 'ro', lazy_build => 1 );
has 'wait_for_status_secs' => ( is => 'ro', default    => 10 );

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

sub _build_bind_addr {
    return "localhost";
}

sub _build_description {
    my $self = shift;
    my $name;
    if ( my $root_dir = defined( $self->root_dir ) ) {
        $name = basename($root_dir);
    }
    else {
        ( $name = ref($self) ) =~ s/^Server::Control:://;
    }
    return "server '$name'";
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

sub _build_port {
    die "cannot determine port";
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

    my $cmd =
         $params{cmd}
      || $ARGV[0]
      || die "no cmd passed and ARGV[0] is empty";
    my $verbose = $params{verbose};

    my $dispatcher = Log::Dispatch->new();
    $dispatcher->add(
        Log::Dispatch::Screen->new(
            name      => 'screen',
            stderr    => 0,
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
            "cannot start %s - pid file '%s' does not exist, but %s",
            $self->description(),
            $self->pid_file(),
            something_is_listening_msg( $self->port, $self->bind_addr )
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

    if ( $self->_wait_for_status( ACTIVE, 'start' ) ) {
        ( my $status = $self->status_as_string() ) =~ s/running/now running/;
        $log->info($status);
    }
    else {
        $self->_report_error_log_output($error_size_start);
    }
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

    if ( $self->_wait_for_status( INACTIVE, 'stop' ) ) {
        $log->infof( "%s has stopped", $self->description() );
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
            if ( -f $pid_file ) {
                $log->infof(
                    "pid file '%s' contains a non-existing process id '%d'!",
                    $pid_file, $pid );
                $self->_handle_corrupt_pid_file();
                return undef;
            }
        }
    }
}

sub is_listening {
    my ($self) = @_;

    my $is_listening = is_port_active( $self->port(), $self->bind_addr() );
    if ( $log->is_debug ) {
        $log->debugf(
            "%s is listening to %s:%d",
            $is_listening ? "something" : "nothing",
            $self->bind_addr(), $self->port()
        );
    }
    return $is_listening;
}

sub run_command {
    my ( $self, $cmd ) = @_;

    if ( $self->use_sudo() ) {
        $cmd = "sudo $cmd";
    }
    $log->debug("running '$cmd'") if $log->is_debug;
    IPC::System::Simple::run($cmd);
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

sub _wait_for_status {
    my ( $self, $status, $action ) = @_;

    $log->infof("waiting for server $action");
    my $wait_until = time() + $self->wait_for_status_secs();
    my $poll_delay = $self->poll_for_status_secs() * 1_000_000;
    while ( time() < $wait_until ) {
        if ( $self->status == $status ) {
            return 1;
        }
        else {
            usleep($poll_delay);
        }
    }

    $log->warnf(
        "after %d secs, %s",
        $self->wait_for_status_secs(),
        $self->status_as_string()
    );
    return 0;
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
        conf_file => '/my/apache/dir/conf/httpd.conf'
    );
    if ( !$apache->is_running() ) {
        $apache->start();
    }

=head1 DESCRIPTION

C<Server::Control> allows you to control servers in the spirit of apachectl,
where a server is any background process which listens to a port and has a pid
file. It is designed to be subclassed for different types of servers.

=head1 FEATURES

=over

=item *

Checks server status in multiple ways (looking for an active process,
contacting the server's port)

=item *

Detects and handles corrupt or out-of-date pid files

=item *

Tails the error log when server fails to start

=item *

Uses sudo by default when using restricted (< 1024) port

=item *

With Unix::Lsof installed, reports what is listening to a port when it is busy

=back

=head1 AVAILABLE SUBCLASSES

The following subclasses are currently available as part of this distribution:

=over

=item *

L<Server::Control::Apache|Server::Control::Apache> - Apache httpd

=item *

L<Server::Control::Apache|Server::Control::HTTPServerSimple> -
HTTP::Server::Simple server

=item *

L<Server::Control::Apache|Server::Control::NetServer> - Net::Server server

=back

These will probably be moved into their own distributions once the
implementation stabilizes.

=head1 CONSTRUCTOR

You can pass the following common options to the constructor. Some subclasses
can deduce some of these options without needing an explicit value passed in.
For example, L<Server::Control::Apache|Server::Control::Apache> can deduce many
of these from the Apache conf file.

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

Path to pid file. Will throw an error if this cannot be determined.

=item poll_for_status_secs

Number of seconds (can be fractional) between status checks when waiting for
server start or stop.  Defaults to 0.2.

=item port

At least one port that server will listen to, so that C<Server::Control> can
check it on start/stop. Will throw an error if this cannot be determined. See
also L</bind_addr>.

=item root_dir

Root directory of server, for conf files, log files, etc. This will affect
defaults of other options like I<log_dir>.

=item use_sudo

Whether to use 'sudo' when attempting to start and stop server. Defaults to
true if I<port> < 1024, false otherwise.

=item wait_for_status_secs

Number of seconds to wait for server start or stop before reporting error.
Defaults to 10.

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

=item handle_cmdline (params)

Helper method to process a command-line command for a script like apachectl.
Takes the following key/value parameters:

=over

=item *

I<cmd> - one of start, stop, restart, or ping. It will be called on the
Server::Control object. An appropriate usage error will be thrown for a bad
command. If I<cmd> is not specified, it will be taken from $ARGV[0].

=item *

I<$verbose> - a boolean indicating whether the log level will be set to 'debug'
or 'info'. Would typically come from a -v or --verbose switch. Default false.

=back

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

C<Server::Control> uses L<Log::Any|Log::Any> for logging events. See
L<Log::Any|Log::Any> documentation for how to control where logs get sent, if
anywhere.

The exception is L</handle_cmdline>, which will tell C<Log::Any> to send logs
to STDOUT.

=head1 IMPLEMENTING SUBCLASSES

C<Server::Control> uses L<Moose|Moose>, so ideally subclasses will as well. See
L<Server::Control::Apache|Server::Control::Apache> for an example.

=head2 Subclass methods

=over

=item do_start

This actually starts the server - it is called by L</start> and must be defined
by the subclass. Any parameters to L</start> are passed here. If your server is
started via the command-line, you may want to use L</run_command>.

=item do_stop ($proc)

This actually stops the server - it is called by L</stop> and may be defined by
the subclass. By default, it will send a SIGTERM to the process. I<$proc> is a
L<Proc::ProcessTable::Process|Proc::ProcessTable::Process> object representing
the current process, as returned by L</is_running>.

=item run_command ($cmd)

Runs the specified I<$cmd> on the command line. Adds sudo if necessary (see
L</use_sudo>), logs the command, and throws runtime errors appropriately.

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

Write a plugin to dynamically generate conf files

=back

=head1 ACKNOWLEDGMENTS

This module was developed for the Digital Media group of the Hearst
Corporation, a diversified media company based in New York City.  Many thanks
to Hearst management for agreeing to this open source release.

=head1 AUTHOR

Jonathan Swartz

=head1 COPYRIGHT & LICENSE

Copyright (C) 2007 Jonathan Swartz, all rights reserved.

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
