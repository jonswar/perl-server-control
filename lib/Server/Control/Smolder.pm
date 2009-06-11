package Server::Control::Smolder;
use File::Slurp;
use Moose;
use Smolder::Conf qw(Port);
use strict;
use warnings;

extends 'Server::Control::Simple';

has '+port' => ( default => Port() );

__PACKAGE__->meta->make_immutable();

sub do_start {
    my $self = shift;

    # Run start(), instead of background()
    my $pid = $self->server->start();
    write_file( $self->pid_file, $pid );
}

1;
