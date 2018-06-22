package PerldocBrowser::Command::index;

# This software is Copyright (c) 2018 by Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
use Mojo::Base 'Mojolicious::Command';
use Pod::Simple::Search;
use experimental 'signatures';

has description => 'Index perldocs for search';
has usage => "Usage: $0 index [all | <version> ...]\n";

sub run ($self, @versions) {
  die $self->usage unless @versions;
  if ($versions[0] eq 'all') {
    @versions = @{$self->app->perl_versions};
  }
  my $db = $self->app->pg->db;
  foreach my $version (@versions) {
    my $inc_dirs = $self->app->inc_dirs($version) // [];
    my $pod_paths = Pod::Simple::Search->new->inc(0)->survey(@$inc_dirs);
    my $tx = $db->begin;
    $self->app->clear_pod_index($db, $version);
    foreach my $pod (keys %$pod_paths) {
      print "Indexing $pod for $version ($pod_paths->{$pod})\n";
      $self->app->index_pod($db, $version, $pod, $pod_paths->{$pod});
    }
    $tx->commit;
  }
}

1;
