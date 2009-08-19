package Server::Control::HTTPServerSimple;
use Carp;
use Server::Control::Util qw(dp);
use Moose;
use Moose::Meta::Class;
use strict;
use warnings;

extends 'Server::Control';

has 'server_class' => ( is => 'ro', isa => 'Str', required => 1 );
has 'server'           => ( is => 'ro', lazy_build => 1 );
has 'net_server_class' => ( is => 'ro', isa        => 'Str' );
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

sub _build_server {
    my $self = shift;
    Class::MOP::load_class( $self->server_class );

    # If net_server_class is provided, create an anon subclass of server_class to use it
    my $server_class;
    if ( my $net_server_class = $self->net_server_class ) {
        Class::MOP::load_class($net_server_class);
        $server_class = Moose::Meta::Class->create_anon_class(
            superclasses => [ $self->server_class ],
            methods      => {
                net_server => sub { $net_server_class }
            },
            cache => 1
        )->name;
    }
    else {
        $server_class = $self->server_class();
    }
    return $server_class->new( $self->port );
}

sub do_start {
    my $self = shift;

    $self->server->background( %{ $self->net_server_params } );
}

1;

__END__

=pod

=head1 NAME

Server::Control::HTTPServerSimple -- apachectl style control for
HTTP::Server::Simple servers

=head1 SYNOPSIS

    package My::Server;
    use base qw(HTTP::Server::Simple);

    ---

    use Server::Control::HTTPServerSimple;
    my $ctl = Server::Control::HTTPServerSimple->new(
        server_class => 'My::Server',
        net_server_class  => 'Net::Server::PreForkSimple',
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

C<Server::Control::HTTPServerSimple> is a subclass of
L<Server::Control|Server::Control> for HTTP::Server::Simple servers.

This must be used with a net_server class specified

=head1 CONSTRUCTOR

The constructor options are as described in L<Server::Control|Server::Control>,
except for:

=over

=item server_class

Required. Specifies a C<HTTP::Server::Simple> subclass. Will be loaded if not
already.

=item net_server_class

Specifies a C<Net::Server> subclass. This needs to either be specified here or
in the HTTP::Server::Simple subclass. Will be loaded if not already.

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
