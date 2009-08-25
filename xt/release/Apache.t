#!perl -w
use Server::Control::t::Apache;
Test::Class::runtests(Server::Control::t::Apache->new);
