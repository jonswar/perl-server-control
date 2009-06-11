package Server::Control::Simple;
use Moose;
use strict;
use warnings;

has 'server' => ( is => 'ro', isa => 'HTTP::Server::Simple', required => 1 );

extends 'Server::Control';

__PACKAGE__->meta->make_immutable();

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
