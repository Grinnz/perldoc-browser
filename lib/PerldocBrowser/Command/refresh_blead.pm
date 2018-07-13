package PerldocBrowser::Command::refresh_blead;

# This software is Copyright (c) 2018 by Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
use Mojo::Base 'Mojolicious::Command';
use Capture::Tiny 'capture_merged';
use version;
use experimental 'signatures';

has description => 'Refresh Blead Perl for Perldoc Browser';
has usage => "Usage: $0 refresh_blead\n";

sub run ($self, @versions) {
  $self->app->perls_dir->child('bleads')->make_path;
  $self->app->home->child('log')->make_path;
  my $date = time;
  my $target = $self->app->perls_dir->child('bleads', $date);
  my $logfile = $self->app->home->child('log', "perl-build-blead.log");
  print "Installing Perl blead to $target ...\n";
  my @args = ('--noman', '-Dusedevel', '--symlink-devel-executables');
  my ($output, $exit) = capture_merged { system 'perl-build', @args, 'blead', $target };
  $logfile->spurt($output);
  if ($exit) {
    print "Failed to install Perl blead to $target (logfile can be found at $logfile)\n";
  } else {
    print "Installed Perl blead to $target\n";
    my $link = $self->app->perls_dir->child('blead');
    symlink $target, $link or die "Failed to symlink $target to $link: $!";
    print "Reassigned Perl blead symlink to $target\n";
    $self->app->perls_dir->child('bleads')->list({dir => 1})->grep(sub { $_->basename ne $date })->each(sub {
      $_->remove_tree;
      print "Removed old Perl blead $_\n";
    });
  }
}

1;
