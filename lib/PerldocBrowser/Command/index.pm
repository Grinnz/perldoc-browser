package PerldocBrowser::Command::index;

# This software is Copyright (c) 2018 by Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
use Mojo::Base 'Mojolicious::Command';
use experimental 'signatures';

has description => 'Index perldocs for search';
has usage => "Usage: $0 index [all | <version> ...]\n";

sub run ($self, @versions) {
  die $self->usage unless @versions;
  if ($versions[0] eq 'all') {
    @versions = @{$self->app->all_perl_versions};
  }
  foreach my $version (@versions) {
    my $pod_paths = $self->app->pod_paths($version);
    $self->app->index_perl_version($version, $pod_paths);
  }
}

1;
