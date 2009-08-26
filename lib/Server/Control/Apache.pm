package Server::Control::Apache;
use Apache::ConfigParser;
use Cwd qw(realpath);
use File::Spec::Functions qw(catdir catfile);
use File::Which qw(which);
use Log::Any qw($log);
use Moose;
use strict;
use warnings;

extends 'Server::Control';

has 'conf_file'     => ( is => 'ro', lazy_build => 1 );
has 'httpd_binary'  => ( is => 'ro', lazy_build => 1 );
has 'parsed_config' => ( is => 'ro', lazy_build => 1, init_arg => undef );
has 'root_dir'      => ( is => 'ro', lazy_build => 1 );

__PACKAGE__->meta->make_immutable();

sub BUILD {
    my ( $self, $params ) = @_;

    # Ensure that we have an existent conf_file after object is built. It
    # can come from the conf_file or root_dir parameter.
    #
    if ( my $conf_file = $self->{conf_file} ) {
        die "no such conf file '$conf_file'" unless -f $conf_file;
        $self->{conf_file} = realpath( $self->{conf_file} );
    }
    elsif ( defined( $self->{root_dir} ) ) {
        $self->{root_dir} = realpath( $self->{root_dir} );
        my $default_conf_file =
          catfile( $self->{root_dir}, "conf", "httpd.conf" );
        if ( -f $default_conf_file ) {
            $self->{conf_file} = $default_conf_file;
            $log->debugf( "defaulting conf file to '%s'", $default_conf_file )
              if $log->is_debug;
            return;
        }
        else {
            die
              "no conf_file specified and cannot find at '$default_conf_file'";
        }
    }
    else {
        die "no conf_file or root_dir specified";
    }
}

sub _build_httpd_binary {
    my $self  = shift;
    my $httpd = ( which('httpd') )[0]
      or die "no httpd_binary specified and cannot find in path";
    $log->debugf("setting httpd_binary to '$httpd'") if $log->is_debug;
    return $httpd;
}

sub _build_parsed_config {
    my $self      = shift;
    my $cp        = Apache::ConfigParser->new;
    my $conf_file = $self->conf_file;
    $cp->parse_file($conf_file)
      or die "problem parsing conf file '$conf_file': " . $cp->errstr;

    my %parsed_config = map {
        my ($directive) = ( $cp->find_down_directive_names($_) );
        defined($directive) ? ( $_, $directive->value ) : ()
    } qw(ServerRoot Listen PidFile ErrorLog);
    $log->debugf( "found these values in parsed '%s': %s",
        $conf_file, \%parsed_config )
      if $log->is_debug;

    return \%parsed_config;
}

sub _build_root_dir {
    my $self = shift;
    if ( my $root_dir = $self->parsed_config->{ServerRoot} ) {
        return $root_dir;
    }
    else {
        die "no root_dir specified and cannot determine from conf file";
    }
}

sub _build_pid_file {
    my $self = shift;
    if ( my $pid_file = $self->parsed_config->{PidFile} ) {
        return $pid_file;
    }
    else {
        $log->debugf( "defaulting pid_file to %s/%s",
            $self->log_dir, "httpd.pid" )
          if $log->is_debug;
        return catdir( $self->log_dir, "httpd.pid" );
    }
}

sub _build_bind_addr {
    my $self = shift;
    if ( defined( my $listen = $self->parsed_config->{Listen} ) ) {
        if ( my ($bind_addr) = ( $listen =~ /([^:]+):/ ) ) {
            return $bind_addr;
        }
    }
    $log->debugf("defaulting bind_addr to localhost") if $log->is_debug;
    return 'localhost';
}

sub _build_port {
    my $self = shift;
    if ( defined( my $listen = $self->parsed_config->{Listen} ) ) {
        ( my $port = $listen ) =~ s/^.*://;
        return $port;
    }
    else {
        die "no port specified and cannot determine from Listen directive";
    }
}

sub _build_error_log {
    my $self = shift;
    if ( defined( my $error_log = $self->parsed_config->{ErrorLog} ) ) {
        return $error_log;
    }
    else {
        my $error_log = catdir( $self->log_dir, "error_log" );
        $log->debug("defaulting error_log to '$error_log'") if $log->is_debug;
        return $error_log;
    }
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
        root_dir  => '/my/apache/dir'
       # OR    
        conf_file => '/my/apache/dir/conf/httpd.conf'
    );
    if ( !$apache->is_running() ) {
        $apache->start();
    }

=head1 DESCRIPTION

Server::Control::Apache is a subclass of Server::Control for Apache httpd
processes. It has the same basic function as apachectl, only with a richer
feature set.

This module has an associated binary, apachectlp(1), which you may want to use
instead.

=head1 CONSTRUCTOR

The constructor options are as described in L<Server::Control|Server::Control>,
except for:

=over

=item httpd_binary

Path to httpd binary. By default, searches for httpd in the user's PATH and
uses the first one found.

=item conf_file

Path to conf file. Will try to use L<Server::Control/root_dir>/conf/httpd.conf
if C<root_dir> was specified and C<conf_file> was not. Throws an error if it
cannot be determined.

=back

This module can usually determine L<Server::Control/bind_addr>,
L<Server::Control/error_log>, L<Server::Control/pid_file>, and
L<Server::Control/port> by parsing the conf file. However, if the parsing
doesn't work or you wish to override certain values, you can pass them in
manually.

=head1 AUTHOR

Jonathan Swartz

=head1 SEE ALSO

L<apachectlp|apachectlp> L<Server::Control|Server::Control>

=head1 COPYRIGHT & LICENSE

Copyright (C) 2007 Jonathan Swartz.

Server::Control::Apache is provided "as is" and without any express or implied
warranties, including, without limitation, the implied warranties of
merchantibility and fitness for a particular purpose.

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
