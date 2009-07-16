use inc::Module::Install;

name 'Server-Control';
abstract 'Flexible apachectl style control for servers';
all_from 'lib/Server/Control.pm';
author 'Jonathan Swartz <swartz@pobox.com>';

perl_version '5.006';

build_requires 'Test::Class' => 0;
build_requires 'Test::Most'  => 0;

requires 'List::MoreUtils'                  => '0.13';
requires 'Log::Any::Adapter::Log::Dispatch' => '0.02';
requires 'Moose'                            => '0.66';

license 'perl';

auto_install;

WriteAll;
