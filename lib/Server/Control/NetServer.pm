package Server::Control::NetServer;
use Carp;
use Moose;
use strict;
use warnings;

extends 'Server::Control';

has 'server' => (
    is       => 'ro',
    required => 1
);
has '+port' => ( required => 0, lazy => 1, builder => '_build_port' );
has 'run_params' => ( is => 'ro', default => sub { {} } );

__PACKAGE__->meta->make_immutable();

sub _build_port {
    my $self = shift;
    return $self->server->port
      or die "port must be provided to constructor or available from server";
}

sub _build_pid_file {
    my $self = shift;
    return $self->server->pid_file
      or die
      "pid_file must be provided to constructor or available from server";
}

sub do_start {
    my $self = shift;

    # Fork child to start server in background. Child will exit in
    # Net::Server::post_configure. Parent continues with rest of
    # Server::Control::start() to see if the server has started correctly
    # and report status.
    #
    my $child = fork;
    croak "Can't fork: $!" unless defined($child);
    if ( !$child ) {
        my $server = $self->server;
        my %auto_params = ( background => 1 );
        $auto_params{pid_file} = $self->pid_file
          unless ( $server->can('pid_file') && defined( $server->pid_file ) );
        $auto_params{port} = $self->port
          unless ( $server->can('port') && defined( $server->port ) );
        $server->run( %auto_params, %{ $self->run_params }, @_ );
        exit(0);    # Net::Server should exit, but just to be safe
    }
}

1;

__END__

=pod

=head1 NAME

Server::Control::NetServer -- apachectl style control for Net::Server servers

=head1 SYNOPSIS

    package My::Server;
    use base qw(Net::Server);
    sub process_request {
       #...code...
    }

    ---

    use Server::Control::NetServer;

    my $ctl = Server::Control::NetServer->new(
        server   => 'My::Server',
        pid_file => '/path/to/server.pid'
    );
    if ( !$ctl->is_running() ) {
        $ctl->start( ... );
    }


=head1 DESCRIPTION

C<Server::Control::NetServer> is a subclass of
L<Server::Control|Server::Control> for Net::Server servers.

=head1 CONSTRUCTOR

The constructor options are as described in L<Server::Control|Server::Control>,
except for:

=over

=item server

Specifies a C<Net::Server> subclass or pre-built object. Required.

=item pid_file

Must either be provided here, or available from C<server-E<gt>pid_file>. Will
be passed along to C<server-E<gt>run()>.

=item port

Must either be provided here, or available from C<server-E<gt>port>. Will be
passed along to C<server-E<gt>run()>.

=back

=head1 METHODS

The methods are as described in L<Server::Control|Server::Control>, except for:

=over

=item start

Arguments to this method are passed along to C<server-E<gt>run()>, along with
C<background =E<gt> 1>.

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
