package Server::Control::Simple;
use File::Slurp;
use Moose;
use strict;
use warnings;

extends 'Server::Control';

has 'server' => ( is => 'ro', isa => 'HTTP::Server::Simple', required => 1 );
has '+port' => ( required => 0, lazy => 1, builder => '_build_port' );
has '+wait_for_start_secs' => ( default => 1 );
has '+wait_for_stop_secs'  => ( default => 1 );

__PACKAGE__->meta->make_immutable();

sub _build_port {
    my $self = shift;
    return $self->server->port;
}

# Ideally, HTTP::Server::Simple would create the pid on startup and remove
# it on shutdown - otherwise our process detection isn't accurate

sub do_start {
    my $self = shift;

    my $pid = $self->server->background();
    write_file( $self->pid_file, $pid );
}

sub do_stop {
    my ( $self, $proc ) = @_;

    kill 15, $proc->pid;
    unlink( $self->pid_file );
}

1;
