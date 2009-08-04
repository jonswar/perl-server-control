package Server::Control::Apache;
use IPC::System::Simple qw(run);
use Log::Any qw($log);
use Moose;
use strict;
use warnings;

extends 'Server::Control';

has 'httpd_binary' => ( is => 'ro', default    => '/usr/bin/httpd' );
has 'conf_file'    => ( is => 'ro', lazy_build => 1 );
has 'conf_dir'     => ( is => 'ro', lazy_build => 1 );

__PACKAGE__->meta->make_immutable();

sub _build_conf_dir {
    my $self = shift;
    return catdir( $self->root_dir, "conf" );
}

sub _build_conf_file {
    my $self = shift;
    return catdir( $self->conf_dir, 'httpd.conf' );
}

sub _build_pid_file {
    my $self = shift;
    return defined( $self->log_dir )
      ? catdir( $self->log_dir, "httpd.pid" )
      : die "no pid_file specified and cannot determine log_dir";
}

sub do_start {
    my $self = shift;

    $self->send_httpd_command('start');
}

sub do_stop {
    my $self = shift;

    $self->send_httpd_command('stop');
}

sub send_httpd_command {
    my ( $self, $command ) = @_;

    my $httpd_binary = $self->httpd_binary();
    my $conf_file    = $self->conf_file();

    my $cmd = "$httpd_binary -k $command -f $conf_file";
    if ( $self->use_sudo() ) {
        $cmd = "sudo $cmd";
    }
    $log->debug("running '$cmd'") if $log->is_debug;
    run($cmd);
}

1;

__END__

=pod

=head1 NAME

Server::Control::Apache -- Control Apache ala apachtctl

=head1 SYNOPSIS

    use Server::Control::Apache;

    my $apache = Server::Control::Apache->new(
        root_dir     => '/my/apache/dir',
        httpd_binary => '/usr/bin/httpd'
    );
    if ( !$apache->is_running() ) {
        $apache->start();
    }

=head1 DESCRIPTION

Server::Control::Apache is a subclass of Server::Control for Apache httpd
processes. It has the same basic function as apachectl, only with a richer
feature set.

This distribution comes with a binary, apachectlp, which you may want to use
instead of this module.

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
