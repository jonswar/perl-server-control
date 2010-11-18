package Server::Control::Apache;
use Apache::ConfigParser;
use Capture::Tiny;
use Cwd qw(realpath);
use File::Spec::Functions qw(catdir catfile);
use File::Which qw(which);
use IPC::System::Simple qw(run);
use Log::Any qw($log);
use Moose;
use MooseX::StrictConstructor;
use strict;
use warnings;

extends 'Server::Control';

has 'conf_file' => ( is => 'ro', lazy_build => 1, required => 1 );
has 'httpd_binary' => ( is => 'ro', lazy_build => 1 );
has 'parsed_config' => ( is => 'ro', lazy_build => 1, init_arg => undef );
has 'no_parse_config' => ( is => 'ro' );
has 'server_root'     => ( is => 'ro', lazy_build => 1 );
has 'stop_cmd'        => ( is => 'rw', init_arg => undef, default => 'stop' );
has 'validate_url'    => ( is => 'ro' );
has 'validate_regex' => ( is => 'ro', isa => 'RegexpRef' );

sub _cli_option_pairs {
    my $class = shift;
    return (
        $class->SUPER::_cli_option_pairs,
        'f|conf-file=s'    => 'conf_file',
        'b|httpd-binary=s' => 'httpd_binary',
        'no-parse-config'  => 'no_parse_config',
    );
}

around 'new_from_cli' => sub {
    my $orig   = shift;
    my $class  = shift;
    my %params = @_;

    if (   !defined( $params{server_root} )
        && !defined( $params{conf_file} ) )
    {
        $class->_cli_usage("must specify one of -d or -f");
    }
    return $class->$orig(@_);
};

override 'valid_cli_actions' => sub {
    return ( super(), qw(graceful graceful-stop) );
};

sub BUILD {
    my ($self) = @_;

    $self->_validate_conf_file();
}

sub _validate_conf_file {
    my ($self) = @_;

    # Ensure that we have an existent conf_file after object is built. It
    # can come from the conf_file or server_root parameter.
    #
    if ( my $conf_file = $self->{conf_file} ) {
        die "no such conf file '$conf_file'" unless -f $conf_file;
        $self->{conf_file} = realpath($conf_file);
    }
    elsif ( my $server_root = $self->{server_root} ) {
        die "no such server root '$server_root'" unless -d $server_root;
        $self->{server_root} = realpath($server_root);
        my $default_conf_file =
          catfile( $self->{server_root}, "conf", "httpd.conf" );
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
        die "no conf_file or server_root specified";
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
    my $self = shift;
    return {} if $self->no_parse_config;

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

sub _build_server_root {
    my $self = shift;
    if ( my $server_root = $self->parsed_config->{ServerRoot} ) {
        return $server_root;
    }
    else {
        die "no server_root specified and cannot determine from conf file";
    }
}

sub _build_pid_file {
    my $self = shift;
    if ( my $pid_file = $self->parsed_config->{PidFile} ) {
        return $self->_rel2abs($pid_file);
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
        return $self->_rel2abs($error_log);
    }
    else {
        my $error_log = catdir( $self->log_dir, "error_log" );
        $log->debug("defaulting error_log to '$error_log'") if $log->is_debug;
        return $error_log;
    }
}

sub do_start {
    my $self = shift;

    $self->check_conf_syntax();
    $self->run_httpd_command('start');
}

sub do_stop {
    my $self = shift;

    $self->run_httpd_command( $self->stop_cmd() );
}

override 'hup' => sub {
    my $self = shift;
    $self->check_conf_syntax();
    super();
};

sub check_conf_syntax {
    my $self         = shift;
    my $httpd_binary = $self->httpd_binary();
    my $conf_file    = $self->conf_file();
    my $cmd          = "$httpd_binary -t -f $conf_file";

    # To avoid printing 'syntax ok', use system() with output captured
    # first; if error result, then use run() for error processing
    my $result;
    Capture::Tiny::capture_merged { $result = system($cmd) };
    if ($result) {
        run($cmd);
    }
}

sub graceful_stop {
    my $self = shift;

    $self->stop_cmd('graceful-stop');
    $self->stop();
}

sub graceful {
    my $self = shift;

    my $proc = $self->_ensure_is_running() or return;
    $self->_warn_if_different_user($proc);

    my $error_size_start = $self->_start_error_log_watch();

    eval { $self->run_httpd_command('graceful') };
    if ( my $err = $@ ) {
        $log->errorf( "error during graceful restart of %s: %s",
            $self->description(), $err );
    }

    if (
        $self->_wait_for_status(
            Server::Control::ACTIVE(), 'graceful restart'
        )
      )
    {
        $log->info( $self->status_as_string() );
        if ( $self->validate_server() ) {
            $self->successful_start();
            return 1;
        }
    }
    $self->_report_error_log_output($error_size_start);
    return 0;
}

sub run_httpd_command {
    my ( $self, $command ) = @_;

    my $httpd_binary = $self->httpd_binary();
    my $conf_file    = $self->conf_file();

    my $cmd = "$httpd_binary -k $command -f $conf_file";
    $self->run_system_command($cmd);
}

sub validate_server {
    my ($self) = @_;

    if ( defined( my $url = $self->validate_url ) ) {
        require LWP;
        $url = sprintf( "http://%s%s%s",
            $self->bind_addr,
            ( $self->port == 80 ? '' : ( ":" . $self->port ) ), $url )
          if substr( $url, 0, 1 ) eq '/';
        $log->infof( "validating url '%s'", $url );
        my $ua  = LWP::UserAgent->new;
        my $res = $ua->get($url);
        if ( $res->is_success ) {
            if ( my $regex = $self->validate_regex ) {
                if ( $res->content !~ $regex ) {
                    $log->errorf(
                        "content of '%s' (%d bytes) did not match regex '%s'",
                        $url, length( $res->content ), $regex );
                    return 0;
                }
            }
            $log->debugf("validation successful") if $log->is_debug;
            return 1;
        }
        else {
            $log->errorf( "error getting '%s': %s", $url, $res->status_line );
            return 0;
        }
    }
    else {
        return 1;
    }
}

sub _rel2abs {
    my ( $self, $path ) = @_;

    if ( substr( $path, 0, 1 ) ne '/' ) {
        $path = join( '/', $self->server_root, $path );
    }
    return $path;
}

__PACKAGE__->meta->make_immutable();

1;

__END__

=pod

=head1 NAME

Server::Control::Apache -- Control Apache ala apachtctl

=head1 SYNOPSIS

    use Server::Control::Apache;

    my $apache = Server::Control::Apache->new(
        server_root  => '/my/apache/dir'
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

This module has an associated binary, L<apachectlp|apachectlp>, which you may
want to use instead.

=head1 CONSTRUCTOR

In addition to the constructor options described in
L<Server::Control|Server::Control>:

=over

=item conf_file

Path to conf file. Will try to use
L<Server::Control/server_root>/conf/httpd.conf if C<server_root> was specified
and C<conf_file> was not. Throws an error if it cannot be determined.

=item httpd_binary

Path to httpd binary. By default, searches for httpd in the user's PATH and
uses the first one found.

=item no_parse_config

Don't attempt to parse the httpd.conf; only look at values passed in the usual
ways.

=item validate_url

A URL to visit after the server has been started or HUP'd, in order to validate
the state of the server. The URL just needs to return an OK result to be
considered valid, unless L</validate_regex> is also specified.

=item validate_regex

A regex to match against the content returned by L</validate_url>. The content
must match the regex for the server to be considered valid.

=back

This module can usually determine L<Server::Control/bind_addr>,
L<Server::Control/error_log>, L<Server::Control/pid_file>, and
L<Server::Control/port> by parsing the conf file. However, if the parsing
doesn't work or you wish to override certain values, you can pass them in
manually.

=head1 METHODS

The following methods are supported in addition to those described in
L<Server::Control|Server::Control>:

=over

=item graceful

Gracefully restart the server - see
http://httpd.apache.org/docs/2.2/stopping.html

=item graceful-stop

Gracefully stop the server - see http://httpd.apache.org/docs/2.2/stopping.html

=back

=head1 TO DO

=over

=item *

Improve exit code from apachectlp - at least 0 for success, 1 for error

=item *

Add configtest action, and test config before apache restart, like apachectl

=back

=head1 AUTHOR

Jonathan Swartz

=head1 SEE ALSO

L<apachectlp|apachectlp>, L<Server::Control|Server::Control>

=head1 COPYRIGHT & LICENSE

Copyright (C) 2007 Jonathan Swartz.

Server::Control::Apache is provided "as is" and without any express or implied
warranties, including, without limitation, the implied warranties of
merchantibility and fitness for a particular purpose.

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
