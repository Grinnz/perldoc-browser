package PerldocBrowser::Command::remove;

# This software is Copyright (c) 2019 by Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
use Mojo::Base 'Mojolicious::Command';
use experimental 'signatures';

has description => 'Remove Perls for Perldoc Browser';
has usage => "Usage: $0 remove <version> [<version> ...]\n";

sub run ($self, @versions) {
  $self->app->perls_dir->make_path;
  foreach my $version (@versions) {
    $self->app->unindex_perl_version($version) if defined $self->app->search_backend;
    my $target = $self->app->perls_dir->child($version);
    my $rendered = $self->app->home->child('html', $version);
    next unless -e $target;
    $target->remove_tree;
    $rendered->remove_tree if -e $rendered;
    print "Removed Perl $version from $target\n";
  }
}

1;
