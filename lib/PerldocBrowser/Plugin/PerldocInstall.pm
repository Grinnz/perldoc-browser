package PerldocBrowser::Plugin::PerldocInstall;

# This software is Copyright (c) 2019 Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
use Mojo::Base 'Mojolicious::Plugin';
use Capture::Tiny 'capture_merged';
use File::Basename 'fileparse';
use File::Copy;
use File::Path 'make_path';
use File::pushd;
use File::Spec;
use File::Temp;
use IPC::Run3;
use List::Util 'first';
use Mojo::File 'path';
use Mojo::Util 'trim';
use Pod::Simple::Search;
use Syntax::Keyword::Try;
use version;
use experimental 'signatures';

sub register ($self, $app, $conf) {
  $app->helper(missing_core_modules => \&_missing_core_modules);
  $app->helper(download_perl_extracted => \&_download_perl_extracted);
  $app->helper(install_perl => \&_install_perl);
  $app->helper(copy_modules_from_source => \&_copy_modules_from_source);
}

sub _missing_core_modules ($c, $inc_dirs) {
  my $search = Pod::Simple::Search->new->inc(0);
  my $perlmodlib = path($search->find('perlmodlib', @$inc_dirs))->slurp;
  my $in_modules;
  my @modules;
  foreach my $directive (grep { m/^=/ } split /\n\n/, $perlmodlib) {
    if (my ($heading) = $directive =~ m/^=head1\s+(.+)/s) {
      $in_modules = $heading =~ m/THE PERL MODULE LIBRARY/;
    }
    next unless $in_modules;
    next unless my ($module) = $directive =~ m/^=item\s+(\S+)/s;
    $module = trim($c->pod_to_text_content("=pod\n\n$module"));
    next if defined $search->find($module, @$inc_dirs);
    push @modules, $module;
  }
  return \@modules;
}

sub _download_perl_extracted ($c, $perl_version, $dir) {
  require HTTP::Tiny;

  my ($url, $tarball);
  if ($perl_version eq 'blead') {
    $tarball = 'blead.tar.gz';
    $url = 'https://github.com/Perl/perl5/archive/blead.tar.gz';
  } else {
    require CPAN::Perl::Releases;
    my $releases = CPAN::Perl::Releases::perl_tarballs($perl_version =~ s/^perl-//r);
    my $tarball_path = $releases->{'tar.gz'};
    unless (defined $tarball_path) {
      require CPAN::Perl::Releases::MetaCPAN;
      my $releases = CPAN::Perl::Releases::MetaCPAN->new->get;
      foreach my $release (@$releases) {
        next unless ($release->{name} =~ s/^perl-//r) eq ($perl_version =~ s/^perl-//r);
        ($tarball_path) = $release->{download_url} =~ m{/authors/id/(.*)};
        last if defined $tarball_path;
      }
    }
    die "Could not find release of Perl version $perl_version\n" unless defined $tarball_path;

    $tarball = $tarball_path =~ s!.*/!!r;
    $url = "https://cpan.metacpan.org/authors/id/$tarball_path";
  }
  my $tarpath = File::Spec->catfile($dir, $tarball);
  my $http = HTTP::Tiny->new(verify_SSL => 1);
  my $response = $http->mirror($url, $tarpath);
  unless ($response->{success}) {
    my $msg = $response->{status} == 599 ? ", $response->{content}" : "";
    chomp $msg;
    die "Failed to download $url: $response->{status} $response->{reason}$msg\n";
  }

  my ($output, $exit);
  {
    my $in_dir = pushd $dir;
    run3 ['tar', 'xzf', $tarpath], undef, \$output, \$output;
    $exit = $? >> 8;
  }
  die "Failed to extract Perl $perl_version to $dir (exit $exit): $output\n" if $exit;

  my $tarname = fileparse $tarpath, qr/\.tar\.[^.]+/;
  my $build;
  if ($perl_version eq 'blead') {
    opendir my $dh, $dir or die "opendir $dir failed: $!";
    $build = File::Spec->catdir($dir, first { !m/^\./ and $_ ne $tarball } readdir $dh);
  } else {
    $build = File::Spec->catdir($dir, $tarname);
  }
  die "Build directory was not extracted\n" unless defined $build and -d $build;

  return $build;
}

sub _install_perl ($c, $version, $target_dir, $logfile) {
    my $v = eval { version->parse($version =~ s/^perl-//r) };
    if (defined $v and $v < version->parse('v5.6.0')) { # ancient perls
      require Devel::PatchPerl;
      open my $logfh, '>', $logfile or die "Failed to open $logfile for logging: $!\n";

      my $tempdir = File::Temp->newdir;
      my $build = $c->app->download_perl_extracted($version, $tempdir);
      $logfh->print("Downloaded Perl $version to $build\n");

      run3 ['chmod', 'u+w', File::Spec->catfile($build, 'makedepend.SH')], undef, \undef, \undef;
      my $output = capture_merged { try { Devel::PatchPerl->patch_source($version =~ s/^perl-//r, $build) } catch { warn $@ } };
      $logfh->print($output);

      my $in_build = pushd $build;

      my @args = ('-de', "-Dprefix=$target_dir", '-Dman1dir=none', '-Dman3dir=none', '-Uafs');
      run3 ['sh', 'Configure', @args], undef, $logfh, $logfh;
      die "Failed to install Perl $version to $target_dir\n" if $?;
      run3 ['make'], undef, $logfh, $logfh;
      die "Failed to install Perl $version to $target_dir\n" if $?;
      run3 ['make', 'install'], undef, $logfh, $logfh;
      die "Failed to install Perl $version to $target_dir\n" if $?;
    } else {
      my $is_devel = $version eq 'blead' || (defined $v && ($v->{version}[1] % 2)) ? 1 : 0;
      my @args = ('--noman');
      push @args, '-Dusedevel', '-Uversiononly' if $is_devel;
      run3 ['perl-build', @args, $version, $target_dir], undef, "$logfile", "$logfile";
      die "Failed to install Perl $version to $target_dir\n" if $?;
    }
    return $target_dir;
}

my %dist_name_override = (
  'Sys::Syslog::Win32' => 'Sys-Syslog',
  'Sys::Syslog::win32::Win32' => 'Sys-Syslog',
  'Test::Harness::Beyond' => 'Test-Harness',
);

my %dist_path_extra = (
  'Sys::Syslog::Win32' => ['win32'],
  'Sys::Syslog::win32::Win32' => ['win32'],
  'Test::Harness::Beyond' => [qw(lib TAP Harness)],
);

sub _copy_modules_from_source ($c, $perl_version, @modules) {
  my $bin = $c->perls_dir->child($perl_version, 'bin', 'perl');
  my $privlib;
  {
    local $ENV{PERL5OPT} = '';
    run3 [$bin, '-MConfig', '-e', 'print "$Config{installprivlib}\n"'], undef, \$privlib;
  }
  my $exit = $? >> 8;
  die "Failed to retrieve privlib for $bin (exit $exit)\n" if $exit;
  chomp $privlib;

  my $tempdir = File::Temp->newdir;
  my $build = $c->download_perl_extracted($perl_version, $tempdir);

  foreach my $module (@modules) {
    my @parts = split /::/, $module;
    next unless @parts;
    my $dist_name = join '-', @parts;
    $dist_name = $dist_name_override{$module} if defined $dist_name_override{$module};
    my $basename = pop @parts;
    my $pm = "$basename.pm";
    my $pod = "$basename.pod";
    next if -e File::Spec->catfile($privlib, @parts, $pod) or -e File::Spec->catfile($privlib, @parts, $pm);
    my $distdir = first { -d } (map { File::Spec->catdir($build, $_, $dist_name) } qw(ext cpan dist)),
      File::Spec->catdir($build, 'ext', split /-/, $dist_name);
    my @attempts;
    push @attempts, File::Spec->catfile($distdir, $pod), File::Spec->catfile($distdir, $pm),
      File::Spec->catfile($distdir, 'lib', @parts, $pod), File::Spec->catfile($distdir, 'lib', @parts, $pm)
      if defined $distdir;
    my $extra = $dist_path_extra{$module};
    push @attempts, File::Spec->catfile($distdir, @$extra, $pod), File::Spec->catfile($distdir, @$extra, $pm)
      if defined $distdir and defined $extra;
    push @attempts, File::Spec->catfile($build, 'lib', @parts, $pod), File::Spec->catfile($build, 'lib', @parts, $pm);
    my $source_path = first { -e } @attempts;
    unless (defined $source_path) {
      warn "Documentation for module $module not found\n";
      next;
    }
    my $target = File::Spec->catdir($privlib, @parts);
    make_path $target if @parts;
    copy($source_path, $target) or die "Failed to copy $source_path to $target: $!";
    print "Copied $module ($source_path) to $target\n";
  }
}

1;
