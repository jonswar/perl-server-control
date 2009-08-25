#!perl -w
use Server::Control::t::HTTPServerSimple;
Test::Class::runtests(Server::Control::t::HTTPServerSimple->new);
