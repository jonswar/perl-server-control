package Server::Control::Starman;
use File::Slurp qw(read_file);
use File::Which qw(which);
use Log::Any qw($log);
use Moose;
use strict;
use warnings;

extends 'Server::Control';

has 'app_psgi'       => ( is => 'ro', required => 1 );
has 'options'        => ( is => 'ro', required => 1, isa => 'HashRef' );
has 'options_string' => ( is => 'ro', init_arg => undef, lazy_build => 1 );
has 'starman_binary' => ( is => 'ro', lazy_build => 1 );

sub BUILD {
    my ( $self, $params ) = @_;

    $self->{params} = $params;
}

sub _cli_option_pairs {
    my $class = shift;
    return (
        $class->SUPER::_cli_option_pairs,
        'b|starman-binary=s' => 'starman_binary',
    );
}

sub _build_options_string {
    my $self    = shift;
    my %options = %{ $self->{options} };
    return join(
        ' ',
        (
            map { sprintf( "--%s %s", _underscore_to_dash($_), $options{$_} ) }
              keys(%options)
        ),
        "--daemonize",
        "--preload-app"
    );
}

sub _underscore_to_dash {
    my ($str) = @_;
    $str =~ s/_/-/g;
    return $str;
}

sub _build_error_log {
    my $self = shift;
    return $self->options->{error_log};
}

sub _build_pid_file {
    my $self = shift;
    return $self->options->{pid};
}

sub _build_port {
    my $self = shift;
    return $self->options->{port} || die "cannot determine port";
}

sub _build_starman_binary {
    my $self = shift;
    return $self->build_binary('starman');
}

sub do_start {
    my $self = shift;

    $self->run_system_command(
        sprintf( '%s %s %s',
            $self->starman_binary, $self->options_string, $self->app_psgi )
    );
}

# HACK - starman does not show up in Proc::ProcessTable on Linux for some reason!
# Fall back to using /proc directly.
#
sub is_running {
    my ($self) = @_;

    unless ( $^O eq 'linux' ) {
        return $self->SUPER::is_running(@_);
    }
    my $pid_file = $self->pid_file();
    my $pid_contents = eval { read_file($pid_file) };
    if ($@) {
        $log->debugf( "pid file '%s' does not exist", $pid_file )
          if $log->is_debug && !$self->{_suppress_logs};
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

        my $procdir = "/proc/$pid";
        if ( -d $procdir ) {
            my $proc = bless( { pid => $pid, uid => ( stat($procdir) )[4] },
                'Proc::ProcessTable::Process' );
            $log->debugf( "pid file '%s' exists and has valid pid %d",
                $pid_file, $pid )
              if $log->is_debug && !$self->{_suppress_logs};
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

__PACKAGE__->meta->make_immutable();

1;

=pod

=head1 NAME

Server::Control::Starman -- Control Starman

=head1 SYNOPSIS

    use Server::Control::Starman;

    my $starman = Server::Control::Starman->new(
        options => {
            port      => 123,
            error_log => '/path/to/error.log',
            pid_file  => '/path/to/starman.pid'
        },
        starman_binary => '/usr/local/bin/starman'
    );
    if ( !$starman->is_running() ) {
        $starman->start();
    }

=head1 DESCRIPTION

Server::Control::Starman is a subclass of L<Server::Control|Server::Control>
for L<Starman|Starman> processes.

=head1 CONSTRUCTOR

In addition to the constructor options described in
L<Server::Control|Server::Control>:

=over

=item app_psgi

Path to app.psgi; required.

=item options

Options to pass to the starman binary; required. Possible keys include:
C<listen>, C<host>, C<port>, C<workers>, C<backlog>, C<max_requests>, C<user>,
C<group>, C<pid>, and C<error_log>. Underscores are converted to dashes before
passing to starman.

C<--daemonize> and C<--preload-app> are automatically passed to starman; the
only current way to change this is by subclassing and overriding
_build_options_string.

=item starman_binary

Path to starman binary. By default, searches for starman in the user's PATH and
uses the first one found.

=back

This module will determine L<Server::Control/error_log>,
L<Server::Control/pid_file>, and L<Server::Control/port> from the options hash.

=head1 KNOWN BUGS

Will only work under Linux. starman does not show up in
L<Proc::ProcessTable|Proc::ProcessTable> results for some reason. So we have to
check /proc directly for now.

=head1 SEE ALSO

L<Server::Control|Server::Control>, L<Starman|Starman>

=cut

__END__

