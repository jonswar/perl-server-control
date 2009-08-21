package Server::Control::t::HTTPServerSimple;
use base qw(Server::Control::t::Base);
use POSIX qw(geteuid getegid);
use Server::Control::HTTPServerSimple;
use Test::Most;
use strict;
use warnings;

my $test_server_class = Moose::Meta::Class->create_anon_class(
    superclasses => ['HTTP::Server::Simple'],
    methods      => {
        net_server => sub { 'Net::Server::Fork' }
    },
    cache => 1
)->name;

sub create_ctl {
    my $self = shift;

    return Server::Control::HTTPServerSimple->new(
        server_class      => $test_server_class,
        net_server_params => {
            port     => $self->{port},
            pid_file => $self->{pid_file},
            log_file => $self->{log_file},
            user     => geteuid(),
            group    => getegid()
        },
    );
}

sub test_missing_params : Test(2) {
    my $self = shift;

    throws_ok {
        Server::Control::HTTPServerSimple->new(
            server_class      => $test_server_class,
            net_server_params => { port => $self->{port} }
        )->pid_file();
    }
    qr/pid_file must be passed/;
    throws_ok {
        Server::Control::HTTPServerSimple->new(
            server_class      => $test_server_class,
            net_server_params => { pid_file => $self->{pid_file} }
        )->port();
    }
    qr/port must be passed/;
}

sub test_wrong_port : Tests(6) {
    my $self = shift;
    my $ctl  = $self->{ctl};
    $ctl->server;    # create server object with old port

    $self->SUPER::test_wrong_port();
}

1;
