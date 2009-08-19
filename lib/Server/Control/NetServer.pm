package Server::Control::NetServer;
use Carp;
use Server::Control::Util qw(dp);
use Moose;
use strict;
use warnings;

extends 'Server::Control';

has 'net_server_class' => (
    is       => 'ro',
    isa      => 'Str',
    required => 1
);
has 'net_server_params' =>
  ( is => 'ro', isa => 'HashRef', default => sub { {} } );
has '+port' => ( required => 0, lazy => 1, builder => '_build_port' );

__PACKAGE__->meta->make_immutable();

sub _build_port {
    my $self = shift;
    return $self->net_server_params->{port}
      || die "port must be passed in net_server_params";
}

sub _build_pid_file {
    my $self = shift;
    return $self->net_server_params->{pid_file}
      || die "pid_file must be passed in net_server_params";
}

sub _build_error_log {
    my $self            = shift;
    my $server_log_file = $self->net_server_params->{log_file};
    return ( defined($server_log_file) && -f $server_log_file )
      ? $server_log_file
      : undef;
}

sub do_start {
    my $self = shift;

    # Fork child. Child will fork again to start server, and then exit in
    # Net::Server::post_configure. Parent continues with rest of
    # Server::Control::start() to see if the server has started correctly
    # and report status.
    #
    my $child = fork;
    croak "Can't fork: $!" unless defined($child);
    if ( !$child ) {
        Class::MOP::load_class( $self->net_server_class );
        $self->net_server_class->run(
            background => 1,
            %{ $self->net_server_params }
        );
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
        net_server_class  => 'My::Server',
        net_server_params => {
            pid_file => '/path/to/server.pid',
            port     => 5678,
            log_file => '/path/to/file.log'
        }
    );
    if ( !$ctl->is_running() ) {
        $ctl->start(...);
    }

=head1 DESCRIPTION

C<Server::Control::NetServer> is a subclass of
L<Server::Control|Server::Control> for Net::Server servers.

=head1 CONSTRUCTOR

The constructor options are as described in L<Server::Control|Server::Control>,
except for:

=over

=item net_server_class

Required. Specifies a C<Net::Server> subclass. Will be loaded if not already.

=item net_server_params

Specifies a hashref of parameters to pass to the server's C<run()> method.

=item pid_file

Will be taken from L</net_server_params>.

=item port

Will be taken from L</net_server_params>.

=item error_log

If not provided, will attempt to get from C<log_file> key in
L</net_server_params>.

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
