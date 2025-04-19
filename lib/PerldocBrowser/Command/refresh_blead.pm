package PerldocBrowser::Command::refresh_blead;

# This software is Copyright (c) 2018 by Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
use Mojo::Base 'Mojolicious::Command';
use List::Util 1.50 'head';
use Time::Seconds;
use experimental 'signatures';

has description => 'Refresh Blead Perl for Perldoc Browser';
has usage => "Usage: $0 refresh_blead\n";

sub run ($self) {
  $self->app->perls_dir->child('bleads')->make_path;
  $self->app->home->child('log')->make_path;
  my $date = time;
  my $target = $self->app->perls_dir->child('bleads', $date);
  my $logfile = $self->app->home->child('log', "perl-build-blead.log");
  print "Installing Perl blead to $target (logfile can be found at $logfile) ...\n";
  $self->app->install_perl('blead', $target, $logfile);
  print "Installed Perl blead to $target\n";
  my $link = $self->app->perls_dir->child('blead');
  my $exit = system 'ln', '-sfT', $target, $link;
  die "Failed to symlink $target to $link: $!\n" if $exit < 0;
  die "Failed to symlink $target to $link\n" if $exit;
  print "Reassigned Perl blead symlink to $target\n";
  my @bleads = $self->app->perls_dir->child('bleads')->list({dir => 1})->sort(sub { $a->basename <=> $b->basename })->each;
  do { $_->remove_tree; print "Removed old Perl blead $_\n" } for head -2, @bleads;

  my $inc_dirs = $self->app->warmup_inc_dirs('blead');
  my $missing = $self->app->missing_core_modules($inc_dirs);
  $self->app->copy_modules_from_source('blead', @$missing) if @$missing;

  if (defined $self->app->search_backend) {
    my $pod_paths = $self->app->pod_paths('blead', 1);
    $self->app->index_perl_version('blead', $pod_paths);
  }
}

1;
