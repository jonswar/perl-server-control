use inc::Module::Install;

name 'Server-Control';
abstract 'Flexible apachectl style control for servers';
all_from 'lib/Server/Control.pm';
author 'Jonathan Swartz <swartz@pobox.com>';

perl_version '5.006';

build_requires 'Capture::Tiny'        => 0;
build_requires 'File::Path'           => 0;
build_requires 'Guard'                => 0.5;
build_requires 'HTTP::Server::Simple' => 0.28;
build_requires 'Net::Server'          => 0;
build_requires 'POSIX'                => 0;
build_requires 'Test::Class'          => 0;
build_requires 'Test::Log::Dispatch'  => 0;
build_requires 'Test::Most'           => 0;

requires 'Apache::ConfigParser'        => '1.01';
requires 'File::Slurp'                 => '9999.13';
requires 'File::Spec::Functions'       => 0;
requires 'File::Temp'                  => 0;
requires 'File::Which'                 => 0;
requires 'Getopt::Long'                => 0;
requires 'Hash::MoreUtils'             => 0;
requires 'IO::Socket'                  => 0;
requires 'IPC::System::Simple'         => '1.18';
requires 'List::MoreUtils'             => '0.13';
requires 'Log::Any::Adapter::Dispatch' => '0.05';
requires 'Moose'                       => '0.66';
requires 'MooseX::StrictConstructor'   => '0.08';
requires 'Pod::Usage'                  => 0;
requires 'Proc::ProcessTable'          => '0.39';
requires 'Time::HiRes'                 => 0;
requires 'YAML::Any'                   => 0;

recommends 'Unix::Lsof'                => '0.0.9';
recommends 'MooseX::Traits'            => '0.07';

install_script 'bin/apachectlp';

no_index directory => 'lib/Server/Control/t';
no_index directory => 'lib/Server/Control/Test';
no_index package => 'Server::Control::Util';

extra_tests;

license 'perl';

auto_install;

WriteAll;
