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

    $self->server->run( pid_file => $self->pid_file, @_ );
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
    my $ctl = Server::Control::Simple->new( server => $server, pid_file => '/path/to/server.pid' );
    if ( !$ctl->is_running() ) {
        $ctl->start(
           # insert Net::Server arguments here
        );
    }

=head1 DESCRIPTION

C<Server::Control::Simple> is a subclass of L<Server::Control|Server::Control>
for HTTP::Server::Simple servers.

=head1 CONSTRUCTOR

The constructor options are as described in L<Server::Control|Server::Control>,
except for:

=over

=item server

Specifies the C<HTTP::Server::Simple> object. Required. When creating the
server object you should specify a forking implementation for C<net_server>
like C<Net::Server::Fork>, C<Net::Server::PreForkSimple>, or
C<Net::Server::PreFork>. See synopsis for an example and
L<Net::Server|Net::Server> for more details.

=item pid_file

This is required for the base class. It will be passed automatically to
Net::Server.

=item port

This is no longer required since it can be extracted from the server object.

=back

=head1 METHODS

The methods are as described in L<Server::Control|Server::Control>, except for:

=over

=item start

Arguments to this method, normally ignored, are passed along to the C<run>
method on the server object.

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
