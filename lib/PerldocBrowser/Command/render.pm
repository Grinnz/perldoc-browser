package PerldocBrowser::Command::render;

# This software is Copyright (c) 2020 by Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
use Mojo::Base 'Mojolicious::Command';
use Mojo::File 'path';
use Mojo::Util 'encode';
use Digest::SHA 'sha1_hex';
use Pod::Simple::Search;
use experimental 'signatures';

has description => 'Pre-render perldocs to HTML';
has usage => "Usage: $0 render [all | latest | <version> ...]\n";

sub run ($self, @versions) {
  die $self->usage unless @versions;
  if ($versions[0] eq 'all') {
    @versions = grep { $_ ne 'blead' } ('latest', @{$self->app->all_perl_versions});
  }
  my $html_dir = $self->app->home->child('html');
  foreach my $version (@versions) {
    my $url_version = $version eq 'latest' ? '' : $version;
    my $real_version = $version eq 'latest' ? $self->app->latest_perl_version : $version;
    my $inc_dirs = $self->app->inc_dirs($real_version) // [];
    my %pod_paths = %{Pod::Simple::Search->new->inc(0)->laborious(1)->survey(@$inc_dirs)};
    next unless keys %pod_paths;
    my $version_dir = $html_dir->child($version)->remove_tree({keep_root => 1})->make_path;
    foreach my $pod (keys %pod_paths) {
      my $dom = $self->app->prepare_perldoc_html(path($pod_paths{$pod})->slurp, $url_version, $pod);
      my $filename = sha1_hex(encode 'UTF-8', $pod) . '.html';
      $version_dir->child($filename)->spurt(encode 'UTF-8', $dom->to_string);
      print "Rendered $pod for $version to $filename\n";
    }
  }
}

1;
