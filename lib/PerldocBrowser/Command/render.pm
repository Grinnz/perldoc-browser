package PerldocBrowser::Command::render;

# This software is Copyright (c) 2020 by Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
use Mojo::Base 'Mojolicious::Command';
use Mojo::Util 'getopt';
use experimental 'signatures';

has description => 'Pre-render perldocs to HTML';
has usage => "Usage: $0 render [--pods] [--indexes] [--functions] [--variables] [all | latest | <version> ...]\n";

sub run ($self, @args) {
  my %types;
  getopt \@args,
    pods => \$types{pods},
    indexes => \$types{indexes},
    functions => \$types{functions},
    variables => \$types{variables};
  my @versions = @args;
  die $self->usage unless @versions;
  if ($versions[0] eq 'all') {
    @versions = grep { $_ ne 'blead' } ('latest', @{$self->app->all_perl_versions});
  }
  foreach my $version (@versions) {
    $self->app->cache_perl_to_html($version, grep($_, values %types) ? \%types : ());
  }
}

1;
