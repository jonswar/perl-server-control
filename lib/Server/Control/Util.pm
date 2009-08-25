package Server::Control::Util;
use strict;
use warnings;
use base qw(Exporter);

our @EXPORT_OK = qw(
  trim
);

sub trim {
    my ($str) = @_;

    for ($str) { s/^\s+//; s/\s+$// }
    return $str;
}

1;
