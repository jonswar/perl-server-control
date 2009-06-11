package Server::Control;
use Moose;
use Cwd qw(realpath);
use File::Slurp;
use File::Spec::Functions qw(catdir catfile);
use File::Basename;
use IO::Socket;
use IPC::System::Simple qw(run);
use Proc::ProcessTable;
use Time::HiRes qw(usleep);
use strict;
use warnings;

has 'description'         => ( is => 'ro', lazy_build => 1 );
has 'error_log'           => ( is => 'ro', lazy_build => 1 );
has 'log_dir'             => ( is => 'ro', lazy_build => 1 );
has 'name'                => ( is => 'ro', lazy_build => 1 );
has 'pid_file'            => ( is => 'ro', lazy_build => 1 );
has 'port'                => ( is => 'ro', required   => 1 );
has 'root_dir'            => ( is => 'ro', lazy_build => 1 );
has 'use_sudo'            => ( is => 'ro', lazy_build => 1 );
has 'verbose'             => ( is => 'ro' );
has 'wait_for_start_secs' => ( is => 'ro', default    => 5 );
has 'wait_for_stop_secs'  => ( is => 'ro', default    => 5 );

#
# ATTRIBUTE BUILDERS
#

sub _build_description {
    my $self = shift;
    return "server '" . $self->name() . "'";
}

sub _build_error_log {
    my $self = shift;
    return catdir( $self->log_dir, "error_log" );
}

sub _build_log_dir {
    my $self = shift;
    return catdir( $self->root_dir, "logs" );
}

sub _build_name {
    my $self = shift;
    return basename( $self->root_dir );
}

sub _build_pid_file {
    my $self = shift;
    return catdir( $self->log_dir, "httpd.pid" );
}

sub _build_root_dir {
    my $self = shift;
    return realpath( dirname($0) );
}

sub _build_use_sudo {
    my $self = shift;
    return $self->port < 1024;
}

#
# OUTPUT METHODS
#

sub msg {
    my ( $self, $fmt, @params ) = @_;
    printf( "$fmt\n", @params );
}

sub vmsg {
    my $self = shift;
    if ( $self->verbose() ) {
        $self->msg(@_);
    }
}

#
# PUBLIC METHODS
#

sub handle_cmdline {
    my ($self) = @_;

    my $cmd            = $ARGV[0];
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
        $self->msg(
            "pid file does not exist, but something is listening to port %d (another server?)",
            $self->port()
        );
        $self->msg( "cannot start %s", $self->description() );
        return;
    }

    my $error_size_start = $self->_start_error_log_watch();

    unless ( $self->do_start() ) {
        $self->msg( "%s could not be started", $self->description() );
        $self->_report_error_log_output($error_size_start);
        return;
    }

    $self->msg("waiting for server start");
    for ( my $i = 0 ; $i < $self->wait_for_start_secs() * 10 ; $i++ ) {
        last if $self->is_running();
        usleep(100000);
    }

    if ( my $proc = $self->is_running() ) {
        $self->msg( "%s is now running (pid %d) - listening on port %d",
            $self->description, $proc->pid, $self->port );
    }
    else {
        $self->msg( "%s still does not appear to be running after %d secs",
            $self->description(), $self->wait_for_start_secs() );
        $self->_report_error_log_output($error_size_start);
    }
}

sub stop {
    my ($self) = @_;

    my $proc = $self->is_running();
    unless ($proc) {
        $self->msg( "%s not running", $self->description() );
        return;
    }
    my $pid = $proc->pid;

    my ( $uid, $eid ) = ( $<, $> );
    if ( ( $eid || $uid ) && $proc->uid != $uid && !$self->use_sudo() ) {
        $self->msg(
            "warning: process %d is owned by uid %d ('%s'), different than current user %d ('%s'); may not be able to stop server",
            $pid,
            $proc->uid,
            scalar( getpwuid( $proc->uid ) ),
            $uid,
            scalar( getpwuid($uid) )
        );
    }

    unless ( $self->do_stop($proc) ) {
        $self->msg( "%s could not be stopped", $self->description() );
    }
    for ( my $i = 0 ; $i < $self->wait_for_stop_secs() ; $i++ ) {
        usleep(100000);
        last if !$self->is_running() && !$self->_is_port_active();
    }
    if ( my $proc = $self->is_running() ) {
        $self->msg(
            "%s (pid %d) could not could not be stopped gracefully - try again or use 'kill'",
            $self->description(), $pid
        );
    }
    elsif ( $self->_is_port_active() ) {
        $self->msg(
            "%s stopped, but something (possibly process %d or a child) is still listening to port %d",
            $self->description(), $pid, $self->port()
        );
    }
    else {
        $self->msg( "%s stopped", $self->description() );
    }
}

sub restart {
    my ($self) = @_;

    $self->stop();
    if ( $self->is_running() ) {
        $self->msg( "could not stop %s, will not attempt start",
            $self->description() );
    }
    else {
        $self->start();
    }
}

sub ping {
    my ($self) = @_;

    $self->msg( "%s", $self->status_as_string() );
}

sub do_stop {
    my ( $self, $proc ) = @_;

    kill 15, $proc->pid;
}

sub status_as_string {
    my ($self) = @_;

    if ( my $pid = $self->is_running() ) {
        return sprintf( "%s is running (pid %d)", $self->description(), $pid );
    }
    else {
        return sprintf( "%s is not running", $self->description() );
    }
}

sub is_running {
    my ($self) = @_;

    my $pid_file = $self->pid_file();
    if ( -e $pid_file ) {
        my ($pid) = read_file($pid_file);

        unless ( $pid > 0 ) {
            $self->msg( "pid file '%s' does not contain a valid process id!",
                $pid_file );
            $self->_handle_corrupt_pid_file();
            return undef;
        }

        my $ptable = new Proc::ProcessTable();
        if ( my ($proc) = grep { $_->pid == $pid } @{ $ptable->table } ) {
            if ( $self->_is_port_active() ) {
                return $proc;
            }
            else {
                return undef;
            }
        }
        else {
            $self->msg(
                "pid file '%s' contains a non-existing process id '%d'!",
                $pid_file, $pid );
            $self->_handle_corrupt_pid_file();
            return undef;
        }
    }
    else {
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

    return -s $self->error_log() || 0;
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
                    $self->msg( "error log output:\n%s", $buf );
                }
            }
        }
        else {
            $self->msg( "cannot find error log '%s'", $error_log );
        }
    }
}

sub _assert_running {
    my ($self) = @_;

    if ( $self->is_running() ) {
        return 1;
    }
    else {
        $self->msg( "%s not running", $self->description() );
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
        $self->msg( "%s already running (pid %d)",
            $self->description(), $proc->pid );
        return 0;
    }
}

sub _handle_corrupt_pid_file {
    my ($self) = @_;

    my $pid_file = $self->pid_file();
    $self->msg( "deleting bogus pid file '%s'", $pid_file );
    unlink $pid_file;
}

sub _is_port_active {
    my ($self) = @_;

    return IO::Socket::INET->new(
        PeerAddr => "localhost",
        PeerPort => $self->port()
    ) ? 1 : 0;
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



=head1 METHODS

=over

=item 

=item 

=back

=head1 SEE ALSO

=head1 AUTHOR

Jonathan Swartz

=head1 COPYRIGHT & LICENSE

Copyright (C) 2007 Jonathan Swartz, all rights reserved.

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
