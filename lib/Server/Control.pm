package Server::Control;
use File::Basename;
use File::Slurp qw(read_file);
use File::Spec::Functions qw(catdir);
use Getopt::Long;
use Hash::MoreUtils qw(slice_def);
use IPC::System::Simple qw();
use Log::Any qw($log);
use Log::Dispatch::Screen;
use Moose;
use MooseX::StrictConstructor;
use Moose::Util::TypeConstraints;
use Pod::Usage;
use Proc::ProcessTable;
use Time::HiRes qw(usleep);
use Server::Control::Util qw(is_port_active something_is_listening_msg);
use YAML::Any;
use strict;
use warnings;

our $VERSION = '0.10';

#
# ATTRIBUTES
#

# Note: In some cases we use lazy_build rather than specifying required or a
# default, to make life easier for subclasses.
#
has 'bind_addr' => ( is => 'ro', isa => 'Str', lazy_build => 1 );
has 'description' =>
  ( is => 'ro', isa => 'Str', lazy_build => 1, init_arg => undef );
has 'error_log'            => ( is => 'ro', isa => 'Str',  lazy_build => 1 );
has 'log_dir'              => ( is => 'ro', isa => 'Str',  lazy_build => 1 );
has 'name'                 => ( is => 'ro', isa => 'Str',  lazy_build => 1 );
has 'pid_file'             => ( is => 'ro', isa => 'Str',  lazy_build => 1 );
has 'poll_for_status_secs' => ( is => 'ro', isa => 'Num',  default    => 0.2 );
has 'port'                 => ( is => 'ro', isa => 'Int',  lazy_build => 1 );
has 'server_root'          => ( is => 'ro', isa => 'Str' );
has 'use_sudo'             => ( is => 'ro', isa => 'Bool', lazy_build => 1 );
has 'wait_for_status_secs' => ( is => 'ro', isa => 'Int',  default    => 10 );

# These are only for command-line. Would like to prevent their use from regular new()...
#
has 'action' => ( is => 'ro', isa => 'Str' );

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

# See if there is an rc_file, in serverctlrc parameter or in
# server_root/serverctl.yml; if so, read from it and merge with parameters
# passed to constructor.
#
sub BUILDARGS {
    my $class  = shift;
    my %params = @_;

    my $rc_file = delete( $params{serverctlrc} )
      || ( defined( $params{server_root} )
        && "$params{server_root}/serverctl.yml" );
    if ( defined $rc_file && -f $rc_file ) {
        if ( defined( my $rc_params = YAML::Any::LoadFile($rc_file) ) ) {
            die "expected hashref from rc_file '$rc_file', got '$rc_params'"
              unless ref($rc_params) eq 'HASH';
            %$rc_params =
              map { my $val = $rc_params->{$_}; s/\-/_/g; ( $_, $val ) }
              keys(%$rc_params);
            %params = ( %$rc_params, %params );
            $log->debugf( "found rc file '%s' with these parameters: %s",
                $rc_file, $rc_params )
              if $log->is_debug;
        }
    }

    return $class->SUPER::BUILDARGS(%params);
}

sub _build_bind_addr {
    return "localhost";
}

sub _build_error_log {
    my $self = shift;
    return
      defined( $self->log_dir ) ? catdir( $self->log_dir, "error_log" ) : undef;
}

sub _build_description {
    my $self = shift;
    my $name = $self->name;
    return "server '$name'";
}

sub _build_log_dir {
    my $self = shift;
    return defined( $self->server_root )
      ? catdir( $self->server_root, "logs" )
      : undef;
}

sub _build_name {
    my $self = shift;
    my $name;
    if ( defined( my $server_root = $self->server_root ) ) {
        $name = basename($server_root);
    }
    else {
        ( $name = ref($self) ) =~ s/^Server::Control:://;
    }
    return $name;
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

sub start {
    my $self = shift;

    if ( my $proc = $self->is_running() ) {
        ( my $status = $self->status_as_string() ) =~
          s/running/already running/;
        $log->warnf($status);
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

sub run_system_command {
    my ( $self, $cmd ) = @_;

    if ( $self->use_sudo() ) {
        $cmd = "sudo $cmd";
    }
    $log->debug("running '$cmd'") if $log->is_debug;
    IPC::System::Simple::run($cmd);
}

sub valid_cli_actions {
    return qw(start stop restart ping);
}

sub handle_cli {
    my $class = shift;

    # Allow caller to specify alternate class with --class
    #
    my $alternate_class;
    $class->_cli_get_options( [ 'class=s' => \$alternate_class ],
        ['pass_through'] );
    if ( defined $alternate_class ) {
        Class::MOP::load_class($alternate_class);
        return $alternate_class->handle_cli();
    }

    # Create object based on @ARGV options
    #
    my $self = $class->new_with_options(@_);

    # Validate and perform specified action
    #
    $self->_perform_cli_action();
}

# This method and its helpers are modelled after MooseX::Getopt, which
# unfortunately I found both too flaky and not completely suited to my needs.
# If and when things improve, we can hopefully drop it in as a replacement.
#
sub new_with_options {
    my ( $class, %passed_params ) = @_;

    # Get params from command-line
    #
    my %option_pairs = $class->_cli_option_pairs();
    my %cli_params   = $class->_cli_parse_argv( \%option_pairs );

    # Start logging to stdout with appropriate log level
    #
    $class->_setup_cli_logging( \%cli_params );
    delete( @cli_params{qw(quiet verbose)} );

    # Combine passed and command-line params, pass to constructor
    #
    my %params = ( %passed_params, %cli_params );
    return $class->new(%params);
}

#
# PRIVATE METHODS
#

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

sub _cli_parse_argv {
    my ( $class, $option_pairs ) = @_;

    my %cli_params;
    my @spec =
      map { $_ => \$cli_params{ $option_pairs->{$_} } } keys(%$option_pairs);
    $class->_cli_get_options( \@spec, [] );
    %cli_params = slice_def( \%cli_params, keys(%cli_params) );

    $class->_cli_usage( "", 0 ) if !%cli_params;
    $class->_cli_usage( "", 1 ) if $cli_params{help};

    return %cli_params;
}

sub _cli_get_options {
    my ( $class, $spec, $config ) = @_;

    my $parser = new Getopt::Long::Parser( config => $config );
    if ( !$parser->getoptions(@$spec) ) {
        $class->_cli_usage("");
    }
}

sub _cli_option_pairs {
    return (
        'bind-addr=s'            => 'bind_addr',
        'd|server-root=s'        => 'server_root',
        'error-log=s'            => 'error_log',
        'h|help'                 => 'help',
        'k|action=s'             => 'action',
        'log-dir=s'              => 'log_dir',
        'name=s'                 => 'name',
        'pid-file=s'             => 'pid_file',
        'port=s'                 => 'port',
        'q|quiet'                => 'quiet',
        'use-sudo=s'             => 'use_sudo',
        'v|verbose'              => 'verbose',
        'wait-for-status-secs=s' => 'wait_for_status_secs',
    );
}

sub _setup_cli_logging {
    my ( $self, $cli_params ) = @_;

    my $log_level =
        $cli_params->{verbose} ? 'debug'
      : $cli_params->{quiet}   ? 'warning'
      :                          'info';
    my $dispatcher =
      Log::Dispatch->new( outputs =>
          [ [ 'Screen', stderr => 0, min_level => $log_level, newline => 1 ] ]
      );
    Log::Any->set_adapter( 'Dispatch', dispatcher => $dispatcher );
}

sub _perform_cli_action {
    my ($self) = @_;
    my $action = $self->action;

    if ( !defined $action ) {
        $self->_cli_usage("must specify -k");
    }
    elsif ( !grep { $_ eq $action } $self->valid_cli_actions ) {
        $self->_cli_usage(
            sprintf(
                "invalid action '%s' - must be one of %s",
                $action,
                join( ", ", ( map { "'$_'" } $self->valid_cli_actions ) )
            )
        );
    }
    else {
        $self->$action();
    }
}

sub _cli_usage {
    my ( $class, $msg, $verbose ) = @_;

    $msg     ||= "";
    $verbose ||= 0;
    pod2usage( -msg => $msg, -verbose => $verbose, -exitval => 2 );
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

L<Server::Control::Apache> - Apache httpd

=item *

L<Server::Control::HTTPServerSimple> - HTTP::Server::Simple server

=item *

L<Server::Control::NetServer> - Net::Server server

=back

These will probably be moved into their own distributions once the
implementation stabilizes.

=for readme stop

=head1 CONSTRUCTOR PARAMETERS

You can pass the following common parameters to the constructor, or include
them in an L<serverctlrc|rc file>.

Some subclasses can deduce some of these parameters without needing an explicit
value passed in.  For example,
L<Server::Control::Apache|Server::Control::Apache> can deduce many of these
from the Apache conf file.

=over

=item bind_addr

At least one address that the server binds to, so that C<Server::Control> can
check it on start/stop. Defaults to C<localhost>. See also L</port>.

=item error_log

Location of error log. Defaults to I<log_dir>/error_log if I<log_dir> is
defined, otherwise undef. When a server fails to start, Server::Control
attempts to show recent messages in the error log.

=item log_dir

Location of logs. Defaults to I<server_root>/logs if I<server_root> is defined,
otherwise undef.

=item name

Name of the server to be used in output and logs. A generic default will be
chosen if none is provided, based on either L</server_root> or the classname.

=item pid_file

Path to pid file. Will throw an error if this cannot be determined.

=item poll_for_status_secs

Number of seconds (can be fractional) between status checks when waiting for
server start or stop.  Defaults to 0.2.

=item port

At least one port that server will listen to, so that C<Server::Control> can
check it on start/stop. Will throw an error if this cannot be determined. See
also L</bind_addr>.

=item server_root

Root directory of server, for conf files, log files, etc. This will affect
defaults of other parameters like I<log_dir>.

=item serverctlrc

Path to an rc file containing, in YAML form, one or parameters to pass to the
constructor. If not specified, will look for L</server_root>/serverctl.yml.
e.g.

    # This is my serverctl.yml
    use_sudo: 1
    wait_for_status-secs: 5

Parameters passed explicitly to the constructor take precedence over parameters
in an rc file.

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

=back

=head2 Command-line processing

=over

=item handle_cli (constructor_params)

Helper method to implement a command-line script like apachectl, including
processing options from C<@ARGV>. In general the script looks like this:

   #!/usr/bin/perl -w
   use strict;
   use Server::Control::Foo;

   Server::Control::Foo->handle_cli();

This will implement a script that

=over

=item *

Parses options --bind-addr, --error-log, --server-root, etc. to be fed into
C<Server::Control::MyServer> constructor. There is one option for each
constructor parameter, with underscores replaced with dashes.

=item *

Parses options -v|--verbose and -q|--quiet by setting the log level to C<debug>
and C<warning> respectively

=item *

Parses option --class by forwarding the call from C<Server::Control::Foo> to a
different class.

=item *

Parses option -h|--help in the usual way

=item *

Gets an action like 'start' from -k|--action, and calls this on the
C<Server::Control::MyServer> object

=item *

Sends any log output to STDOUT

=back

See L<apachectlp> for an example.

Any parameters passed to C<handle_cli> will be passed to the C<Server::Control>
constructor, but may be overriden by C<@ARGV> options.

In general, any customization to the default command-line handling is best done
in your C<Server::Control> subclass rather than the script itself. For example,
see L<Server::Control::Apache|Server::Control::Apache> and its overriding of
C<_cli_option_pairs>.

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

The exception is L</handle_cli>, which will tell C<Log::Any> to send logs to
STDOUT.

=head1 IMPLEMENTING SUBCLASSES

C<Server::Control> uses L<Moose|Moose>, so ideally subclasses will as well. See
L<Server::Control::Apache|Server::Control::Apache> for an example.

=head2 Subclass methods

=over

=item do_start

This actually starts the server - it is called by L</start> and must be defined
by the subclass. Any parameters to L</start> are passed here. If your server is
started via the command-line, you may want to use L</run_system_command>.

=item do_stop ($proc)

This actually stops the server - it is called by L</stop> and may be defined by
the subclass. By default, it will send a SIGTERM to the process. I<$proc> is a
L<Proc::ProcessTable::Process|Proc::ProcessTable::Process> object representing
the current process, as returned by L</is_running>.

=item run_system_command ($cmd)

Runs the specified I<$cmd> on the command line. Adds sudo if necessary (see
L</use_sudo>), logs the command, and throws runtime errors appropriately.

=back

=for readme continue

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

Add 'refork' action, which kills all children of a forking server

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

Server::Control is provided "as is" and without any express or implied
warranties, including, without limitation, the implied warranties of
merchantibility and fitness for a particular purpose.

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

