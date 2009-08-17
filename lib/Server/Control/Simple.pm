package Server::Control::Simple;
use File::Slurp;
use Moose;
use strict;
use warnings;

extends 'Server::Control';

has 'server' => ( is => 'ro', isa => 'HTTP::Server::Simple', required => 1 );
has '+port' => ( required => 0, lazy => 1, builder => '_build_port' );

__PACKAGE__->meta->make_immutable();

sub _build_port {
    my $self = shift;
    return $self->server->port;
}

sub _build_pid_file {
    die "must specify pid_file";
}

sub do_start {
    my $self = shift;

    $self->server->background();
}

1;

__END__

=pod

=head1 NAME

Server::Control::Simple -- apachectl style control for HTTP::Server::Simple
servers

=head1 SYNOPSIS

    use Server::Control::Simple;

    my $server = HTTP::Server::Simple->new(
        net_server => 'PreForkSimple',
        ...
    );
    my $ctl = Server::Control::Simple->new( server => $server );
    if ( !$ctl->is_running() ) {
        $ctl->start();
    }

=head1 DESCRIPTION

C<Server::Control::Simple> is a subclass of L<Server::Control|Server::Control>
for HTTP::Server::Simple servers.

=head1 CONSTRUCTOR

The constructor options are the same as in L<Server::Control|Server::Control>,
except for:

=over

=item server

Specifies the C<HTTP::Server::Simple> object. Required.

=item port

This is no longer required since it can be extracted from the server object.

=back

=head1 AUTHOR

Jonathan Swartz

=head1 SEE ALSO

L<Server::Control|Server::Control>

=head1 COPYRIGHT & LICENSE

Copyright (C) 2007 Jonathan Swartz.

Server::Control::Apache is provided "as is" and without any express or implied
warranties, including, without limitation, the implied warranties of
merchantibility and fitness for a particular purpose.

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
