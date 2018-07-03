package PerldocBrowser::Command::index;

# This software is Copyright (c) 2018 by Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
use Mojo::Base 'Mojolicious::Command';
use Mojo::File 'path';
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
    my $tx = $db->begin;
    my %pod_paths;
    if ($functions) {
      $pod_paths{perlfunc} = Pod::Simple::Search->new->inc(0)->find('perlfunc', @$inc_dirs);
      $self->app->clear_index($db, $version, 'functions');
    }
    if ($variables) {
      $pod_paths{perlvar} = Pod::Simple::Search->new->inc(0)->find('perlvar', @$inc_dirs);
      $self->app->clear_index($db, $version, 'variables');
    }
    if ($faqs) {
      my $search = Pod::Simple::Search->new->inc(0);
      $pod_paths{"perlfaq$_"} = $search->find("perlfaq$_", @$inc_dirs) for 1..9;
      $self->app->clear_index($db, $version, 'faqs');
    }
    unless ($functions or $variables or $faqs) {
      %pod_paths = %{Pod::Simple::Search->new->inc(0)->laborious(1)->survey(@$inc_dirs)};
      $self->app->clear_index($db, $version, 'pods');
      $self->app->clear_index($db, $version, 'functions');
      $self->app->clear_index($db, $version, 'variables');
      $self->app->clear_index($db, $version, 'faqs');
    }
    foreach my $pod (keys %pod_paths) {
      print "Indexing $pod for $version ($pod_paths{$pod})\n";
      my $src = path($pod_paths{$pod})->slurp;
      $self->app->index_pod($db, $version, $pod, $src) unless $functions or $variables or $faqs;

      if ($pod eq 'perlfunc') {
        print "Indexing functions for $version\n";
        $self->app->index_functions($db, $version, $src);
      } elsif ($pod eq 'perlvar') {
        print "Indexing variables for $version\n";
        $self->app->index_variables($db, $version, $src);
      } elsif ($pod =~ m/^perlfaq[1-9]$/) {
        print "Indexing $pod FAQs for $version\n";
        $self->app->index_faqs($db, $version, $pod, $src);
      }
    }
    $tx->commit;
  }
}

1;
