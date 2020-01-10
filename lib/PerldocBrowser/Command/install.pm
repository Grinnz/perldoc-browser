package PerldocBrowser::Command::install;

# This software is Copyright (c) 2018 by Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
use Mojo::Base 'Mojolicious::Command';
use Capture::Tiny 'capture_merged';
use File::pushd;
use File::Spec;
use File::Temp;
use IPC::Run3;
use Pod::Simple::Search;
use Syntax::Keyword::Try;
use version;
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
    unlink $logfile;
    open my $logfh, '>>', $logfile or die "Failed to open $logfile for logging: $!\n";
    print "Installing Perl $version to $target (logfile can be found at $logfile) ...\n";
    my $v = eval { version->parse($version =~ s/^perl-//r) };
    if (defined $v and $v < version->parse('v5.6.0')) { # ancient perls
      require Devel::PatchPerl;
      
      my $tempdir = File::Temp->newdir;
      my $build = $self->app->download_perl_extracted($version, $tempdir);
      $logfh->print("Downloaded Perl $version to $build\n");
      
      run3 ['chmod', 'u+w', File::Spec->catfile($build, 'makedepend.SH')], undef, \undef, \undef;
      my $output = capture_merged { try { Devel::PatchPerl->patch_source($version =~ s/^perl-//r, $build) } catch { warn $@ } };
      $logfh->print($output);
      
      {      
        my $in_build = pushd $build;
        
        my @args = ('-de', "-Dprefix=$target", '-Dman1dir=none', '-Dman3dir=none');
        run3 ['sh', 'Configure', @args], undef, $logfh, $logfh;
        die "Failed to install Perl $version to $target\n" if $?;
        run3 ['make'], undef, $logfh, $logfh;
        die "Failed to install Perl $version to $target\n" if $?;
        run3 ['make', 'install'], undef, $logfh, $logfh;
        die "Failed to install Perl $version to $target\n" if $?;
      }
      
      print "Installed Perl $version to $target\n";
    } else {
      my $is_devel = $version eq 'blead' || (defined $v && ($v->{version}[1] % 2)) ? 1 : 0;
      my @args = ('--noman');
      push @args, '-Dusedevel', '-Uversiononly' if $is_devel;
      run3 ['perl-build', @args, $version, $target], undef, $logfh, $logfh;
      die "Failed to install Perl $version to $target\n" if $?;
      print "Installed Perl $version to $target\n";
    }

    my $inc_dirs = $self->app->warmup_inc_dirs($version);
    my $missing = $self->app->missing_core_modules($inc_dirs);
    $self->app->copy_modules_from_source($version, @$missing) if @$missing;

    if (defined $self->app->search_backend) {
      my %pod_paths = %{Pod::Simple::Search->new->inc(0)->laborious(1)->survey(@$inc_dirs)};
      $self->app->index_perl_version($version, \%pod_paths);
    }
  }
}

1;

