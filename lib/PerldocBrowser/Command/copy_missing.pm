package PerldocBrowser::Command::copy_missing;

# This software is Copyright (c) 2019 by Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
use Mojo::Base 'Mojolicious::Command';
use Pod::Simple::Search;
use experimental 'signatures';

has description => 'Copy missing platform-specific module files from Perl source tree';
has usage => "Usage: $0 copy_missing <version> [<version> ...]\n";

sub run ($self, @versions) {
  die $self->usage unless @versions;
  foreach my $version (@versions) {
    my $inc_dirs = $self->app->inc_dirs($version);
    my $missing = $self->app->missing_core_modules($inc_dirs);
    $self->app->copy_modules_from_source($version, @$missing) if @$missing;
  }
}

1;

