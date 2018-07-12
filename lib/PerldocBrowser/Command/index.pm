package PerldocBrowser::Command::index;

# This software is Copyright (c) 2018 by Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
use Mojo::Base 'Mojolicious::Command';
use Mojo::Util 'getopt';
use Pod::Simple::Search;
use experimental 'signatures';

has description => 'Index perldocs for search';
has usage => "Usage: $0 index [--functions] [--variables] [--faqs] [all | <version> ...]\n";

sub run ($self, @versions) {
  getopt \@versions, 'functions' => \my $functions, 'variables' => \my $variables, 'faqs' => \my $faqs;
  die $self->usage unless @versions;
  if ($versions[0] eq 'all') {
    @versions = @{$self->app->all_perl_versions};
  }
  my $db = $self->app->pg->db;
  foreach my $version (@versions) {
    my $inc_dirs = $self->app->inc_dirs($version) // [];
    my %pod_paths;
    if ($functions or $variables or $faqs) {
      $pod_paths{perlfunc} = Pod::Simple::Search->new->inc(0)->find('perlfunc', @$inc_dirs) if $functions;
      $pod_paths{perlvar} = Pod::Simple::Search->new->inc(0)->find('perlvar', @$inc_dirs) if $variables;
      if ($faqs) {
        my $search = Pod::Simple::Search->new->inc(0);
        $pod_paths{"perlfaq$_"} = $search->find("perlfaq$_", @$inc_dirs) for 1..9;
      }
      $self->app->index_perl_version($version, \%pod_paths, 0);
    } else {
      %pod_paths = %{Pod::Simple::Search->new->inc(0)->laborious(1)->survey(@$inc_dirs)};
      $self->app->index_perl_version($version, \%pod_paths, 1);
    }
  }
}

1;
