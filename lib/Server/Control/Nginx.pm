package Server::Control::Nginx;
use Log::Any qw($log);
use Moose;
use strict;
use warnings;

extends 'Server::Control';

has 'conf_file'    => ( is => 'ro', required => 1 );
has 'nginx_binary' => ( is => 'ro', lazy_build => 1 );

sub _cli_option_pairs {
    my $class = shift;
    return (
        $class->SUPER::_cli_option_pairs,
        'b|nginx-binary=s' => 'nginx_binary',
    );
}

sub _build_nginx_binary {
    my $self = shift;
    return $self->build_binary('nginx');
}

sub do_start {
    my $self = shift;

    $self->run_system_command(
        sprintf( '%s -c %s', $self->nginx_binary, $self->conf_file ) );
}

sub do_stop {
    my $self = shift;

    $self->run_system_command(
        sprintf( '%s -c %s -s stop', $self->nginx_binary, $self->conf_file ) );
}

__PACKAGE__->meta->make_immutable();

1;

__END__

=pod

=head1 NAME

Server::Control::Nginx -- Control Nginx

=head1 SYNOPSIS

    use Server::Control::Nginx;

    my $nginx = Server::Control::Nginx->new(
        nginx_binary => '/usr/sbin/nginx',
        conf_file => '/path/to/nginx.conf'
    );
    if ( !$nginx->is_running() ) {
        $nginx->start();
    }

=head1 DESCRIPTION

Server::Control::Nginx is a subclass of L<Server::Control|Server::Control> for
L<Nginx|http://nginx.org/> processes.

=head1 CONSTRUCTOR

In addition to the constructor options described in
L<Server::Control|Server::Control>:

=over

=item conf_file

Path to conf file - required.

=item nginx_binary

Path to nginx binary. By default, searches for nginx in the user's PATH and
uses the first one found.

=back

=head1 SEE ALSO

L<Server::Control|Server::Control>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2011 by Jonathan Swartz.

This is free software; you can redistribute it and/or modify it under the same
terms as the Perl 5 programming language system itself.

=cut
