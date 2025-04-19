package PerldocBrowser::Command::install;

# This software is Copyright (c) 2018 by Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
use Mojo::Base 'Mojolicious::Command';
use experimental 'signatures';

has description => 'Install Perls for Perldoc Browser';
has usage => "Usage: $0 install <version> [<version> ...]\n";

sub run ($self, @versions) {
  die $self->usage unless @versions;
  $self->app->perls_dir->make_path;
  $self->app->home->child('log')->make_path;
  foreach my $version (@versions) {
    my $target = $self->app->perls_dir->child($version);
    my $logfile = $self->app->home->child('log', "perl-build-$version.log");
    print "Installing Perl $version to $target (logfile can be found at $logfile) ...\n";
    $target = $self->app->install_perl($version, $target, $logfile);
    print "Installed Perl $version to $target\n";

    $self->app->warmup_perl_versions; # cache inc dirs and latest perl version

    my $inc_dirs = $self->app->inc_dirs($version);
    my $missing = $self->app->missing_core_modules($inc_dirs);
    $self->app->copy_modules_from_source($version, @$missing) if @$missing;

    $self->app->cache_perl_to_html($version) unless $version eq 'blead';
    $self->app->cache_perl_to_html('latest') if $version eq $self->app->latest_perl_version;

    if (defined $self->app->search_backend) {
      my $pod_paths = $self->app->pod_paths($version, 1);
      $self->app->index_perl_version($version, $pod_paths);
    }
  }
}

1;

