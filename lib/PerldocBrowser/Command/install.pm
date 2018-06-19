package PerldocBrowser::Command::install;

# This software is Copyright (c) 2018 by Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
use Mojo::Base 'Mojolicious::Command';
use Capture::Tiny 'capture_merged';
use version;
use experimental 'signatures';

has description => 'Install Perls for Perldoc Browser';
has usage => "Usage: $0 install <version> [<version> ...]\n";

sub run ($self, @versions) {
  $self->app->home->child('perls')->make_path;
  $self->app->home->child('log')->make_path;
  foreach my $version (@versions) {
    my $v = eval { version->parse($version) };
    my $is_devel = defined $v && ($v->{version}[1] % 2) ? 1 : 0;
    my $target = $self->app->home->child('perls', $version);
    $target->remove_tree if -d $target;
    my $logfile = $self->app->home->child('log', "perl-build-$version.log");
    print "Installing Perl $version to $target ...\n";
    my @args = ('--noman');
    push @args, '-Dusedevel', '--symlink-devel-executables' if $is_devel;
    my ($output, $exit) = capture_merged { system 'perl-build', @args, $version, $target };
    $logfile->spurt($output);
    if ($exit) {
      print "Failed to install Perl $version to $target (logfile can be found at $logfile)\n";
    } else {
      print "Installed Perl $version to $target\n";
    }
  }
}

1;

