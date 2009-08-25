package Server::Control::Test::Class;
use Getopt::Long;
use strict;
use warnings;
use base qw(Test::Class);

sub runtests {
    my ($class) = @_;

    # Handle -m flag in case test script is being run directly.
    #
    GetOptions( 'm|method=s' => sub { $ENV{TEST_METHOD} = ".*" . $_[1] . ".*" },
    );

    # Check for -S flag
    #
    if ( $ENV{TEST_STACK_TRACE} ) {

        # Show entire stack trace on fatal errors or warnings
        $SIG{'__DIE__'}  = sub { Carp::confess(@_) };
        $SIG{'__WARN__'} = sub { Carp::confess(@_) };
    }

    # Check for internal_only
    #
    if ( $class->internal_only && !$class->is_internal ) {
        $class->skip_all('internal test only');
    }

    # Only run tests directly in $class.
    #
    my $test_obj = $class->new();
    Test::Class::runtests($test_obj);
}

sub is_internal {
    return $ENV{RELEASE_TESTING};
}

sub internal_only {
    return 0;
}

1;
