package Server::Control::Apache;
use File::Spec::Functions qw(catdir);
use File::Which qw(which);
use Moose;
use strict;
use warnings;

extends 'Server::Control';

has 'httpd_binary' => ( is => 'ro', lazy_build => 1 );
has 'conf_file'    => ( is => 'ro', lazy_build => 1 );
has 'conf_dir'     => ( is => 'ro', lazy_build => 1 );

__PACKAGE__->meta->make_immutable();

sub _build_httpd_binary {
    my $self  = shift;
    my $httpd = scalar( which('httpd') )
      or die "no httpd_binary specified and cannot find in path";
}

sub _build_conf_dir {
    my $self = shift;
    return
      defined( $self->root_dir ) ? catdir( $self->root_dir, "conf" ) : undef;
}

sub _build_conf_file {
    my $self = shift;
    return defined( $self->conf_dir )
      ? catdir( $self->conf_dir, 'httpd.conf' )
      : die "no conf_file specified and cannot determine conf_dir";
}

sub _build_pid_file {
    my $self = shift;
    return defined( $self->log_dir )
      ? catdir( $self->log_dir, "httpd.pid" )
      : die "no pid_file specified and cannot determine log_dir";
}

sub do_start {
    my $self = shift;

    $self->run_httpd_command('start');
}

sub do_stop {
    my $self = shift;

    $self->run_httpd_command('stop');
}

sub run_httpd_command {
    my ( $self, $command ) = @_;

    my $httpd_binary = $self->httpd_binary();
    my $conf_file    = $self->conf_file();

    my $cmd = "$httpd_binary -k $command -f $conf_file";
    $self->run_command($cmd);
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

=head1 CONSTRUCTOR

The constructor options are as described in L<Server::Control|Server::Control>,
except for:

=over

=item httpd_binary

Path to httpd binary. By default, searches for httpd in the user's PATH.

=item conf_dir

Path to conf dir. Will try to use L<Server::Control/root_dir>/conf if not
specified.

=item conf_file

Path to conf file. Will try to use L</conf_dir>/httpd.conf if not specified.
Throws an error if it cannot be determined.

=item pid_file

Defaults to L<Server::Control/log_dir>/httpd.pid, the Apache default.

=back

=head1 TODO

=over

=item *

Parse Apache config to determine things like port, bind_addr, error_log, and
pid_file.

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
