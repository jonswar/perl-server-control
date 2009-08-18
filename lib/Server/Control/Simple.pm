package Server::Control::Simple;
use Moose;
use Moose::Util::TypeConstraints;
use strict;
use warnings;

extends 'Server::Control::NetServer';

subtype 'Server::Control::Simple::WithNetServer' => as 'HTTP::Server::Simple' =>
  where { defined( $_->net_server() ) } => message {
    'must be an HTTP::Server::Simple subclass with a net_server defined';
  };
has '+server' => ( isa      => 'Server::Control::Simple::WithNetServer' );
has '+port'   => ( required => 1 );

__PACKAGE__->meta->make_immutable();

sub _build_pid_file {
    die "pid_file must be provided to constructor";
}

1;

__END__

=pod

=head1 NAME

Server::Control::Simple -- apachectl style control for HTTP::Server::Simple
servers

=head1 SYNOPSIS

    package My::Server;
    use base qw(HTTP::Server::Simple::CGI);
    sub net_server { 'PreForkSimple' }

    ---

    use Server::Control::Simple;

    my $server = My::Server->new( ... );
    my $ctl = Server::Control::Simple->new( server => $server, pid_file => '/path/to/server.pid' );
    if ( !$ctl->is_running() ) {
        $ctl->start( ... );
    }

=head1 DESCRIPTION

C<Server::Control::Simple> is a subclass of L<Server::Control|Server::Control>
for HTTP::Server::Simple servers.

=head1 CONSTRUCTOR

The constructor options are as described in L<Server::Control|Server::Control>,
except for:

=over

=item server

Specifies a C<HTTP::Server::Simple> based object. Required.

=item pid_file

Required. Will be passed along to C<server-E<gt>run()>.

=item port

Must either be provided here, or available from C<server-E<gt>port>. Will be
passed along to C<server-E<gt>run()>.

=back

=head1 METHODS

The methods are as described in L<Server::Control|Server::Control>, except for:

=over

=item start

Arguments to this method are passed along to C<server-E<gt>run()>.

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
