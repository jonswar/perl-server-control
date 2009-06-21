package Server::Control::Test::Testable;
use Server::Control::Util qw(dump_one_line);
use List::MoreUtils qw(first_index);
use Moose::Role;
use Test::Builder;
use strict;
use warnings;

has 'msgs' => (is => 'ro', default => sub { [] });

sub msg {
    my ( $self, $fmt, @params ) = @_;

    my $msg = sprintf( "$fmt\n", @params );
    push(@{$self->msgs}, $msg);
    Test::Most::explain("** $msg");
}

sub output_contains {
    my ( $self, $regex ) = @_;
    my $tb = Test::Builder->new();

    my $found = first_index { /$regex/ } @{ $self->msgs };
    if ( $found != -1 ) {
        splice( @{ $self->{msgs} }, $found, 1 );
        $tb->ok( 1, "found message matching $regex" );
    }
    else {
        $tb->ok( 0,
            "could not find message matching $regex; log contains: "
              . dump_one_line( $self->{msgs} ) );
    }
}

sub output_contains_only {
    my $self = shift;

    $self->output_contains(@_);
    $self->output_is_empty();
}

sub output_clear {
    my ($self) = @_;

    $self->{msgs} = [];
}

sub output_is_empty {
    my ($self) = @_;
    my $tb = Test::Builder->new();

    if ( !@{ $self->{msgs} } ) {
        $tb->ok( 1, "log is empty" );
    }
    else {
        $tb->ok( 0,
            "log is not empty; contains " . dump_one_line( $self->{msgs} ) );
    }
}

1;
