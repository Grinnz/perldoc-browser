package PerldocBrowser::Command::refresh_blead;

# This software is Copyright (c) 2018 by Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
use Mojo::Base 'Mojolicious::Command';
use experimental 'signatures';

has description => 'Refresh Blead Perl for Perldoc Browser';
has usage => "Usage: $0 refresh_blead\n";

sub run ($self) {
  my $bleads_dir = $self->app->perls_dir->child('bleads')->make_path;
  my $log_dir = $self->app->home->child('log')->make_path;
  my $date = time;
  my $target = $bleads_dir->child($date);
  my $logfile = $log_dir->child('perl-build-blead.log');
  print "Installing Perl blead to $target (logfile can be found at $logfile) ...\n";
  $self->app->install_perl('blead', $target, $logfile);
  print "Installed Perl blead to $target\n";
  $self->app->relink_blead($target);
  print "Reassigned Perl blead symlink to $target\n";
  my $removed = $self->app->cleanup_bleads($bleads_dir, 2);
  print "Removed old Perl bleads @$removed\n" if @$removed;

  my $inc_dirs = $self->app->warmup_inc_dirs('blead');
  my $missing = $self->app->missing_core_modules($inc_dirs);
  $self->app->copy_modules_from_source('blead', @$missing) if @$missing;

  if (defined $self->app->search_backend) {
    my $pod_paths = $self->app->pod_paths('blead', 1);
    $self->app->index_perl_version('blead', $pod_paths);
  }
}

1;
