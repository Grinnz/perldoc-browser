package PerldocBrowser::Plugin::PerldocInstall;

# This software is Copyright (c) 2019 Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
use Mojo::Base 'Mojolicious::Plugin';
use File::Basename 'fileparse';
use File::Copy;
use File::Path 'make_path';
use File::pushd;
use File::Spec;
use File::Temp;
use IPC::Run3;
use List::Util 'first';
use Mojo::File 'path';
use Mojo::Util qw(encode sha1_sum trim);
use Pod::Simple::Search;
use experimental 'signatures';

sub register ($self, $app, $conf) {
  $app->helper(missing_core_modules => \&_missing_core_modules);
  $app->helper(download_perl_extracted => \&_download_perl_extracted);
  $app->helper(copy_modules_from_source => \&_copy_modules_from_source);
  $app->helper(cache_perl_to_html => \&_cache_perl_to_html);
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

sub _cache_perl_to_html ($c, $perl_version) {
  my $url_version = my $real_version = my $path_version = $perl_version;
  if ($perl_version eq 'latest') {
    $url_version = '';
    $real_version = $c->app->latest_perl_version;
    $path_version = "latest-$real_version";
  }
  my $pod_paths = $c->app->pod_paths($real_version) // {};
  return unless keys %$pod_paths;
  my $version_dir = $c->app->home->child('html', $path_version)->remove_tree({keep_root => 1})->make_path;
  foreach my $pod (keys %$pod_paths) {
    my $filename = sha1_sum(encode 'UTF-8', $pod) . '.html';
    print "Rendering $pod for $perl_version to $filename\n";
    my $dom = $c->app->prepare_perldoc_html(path($pod_paths->{$pod})->slurp, $url_version, $pod_paths, $pod);
    $version_dir->child($filename)->spew(encode 'UTF-8', $dom->to_string);
  }
  if (defined $pod_paths->{perlfunc}) {
    my $functions_dir = $version_dir->child('functions')->make_path;
    my $perlfunc_pod = path($pod_paths->{perlfunc})->slurp;
    my %functions = map { ($_ => 1) } map { @{$_->{names}} } @{$c->split_functions($perlfunc_pod)};
    foreach my $function (keys %functions) {
      my $filename = sha1_sum(encode 'UTF-8', $function) . '.html';
      print "Rendering function $function for $perl_version to $filename\n";
      my $function_pod = $c->function_pod_page($perlfunc_pod, $function);
      my $dom = $c->app->prepare_perldoc_html($function_pod, $url_version, $pod_paths, 'functions', $function);
      $functions_dir->child($filename)->spew(encode 'UTF-8', $dom->to_string);
    }
  }
  if (defined $pod_paths->{perlvar}) {
    my $variables_dir = $version_dir->child('variables')->make_path;
    my $perlvar_pod = path($pod_paths->{perlvar})->slurp;
    my %variables = map { ($_ => 1) } map { @{$_->{names}} } @{$c->split_variables($perlvar_pod)};
    foreach my $variable (keys %variables) {
      my $filename = sha1_sum(encode 'UTF-8', $variable) . '.html';
      print "Rendering variable $variable for $perl_version to $filename\n";
      my $variable_pod = $c->variable_pod_page($perlvar_pod, $variable);
      my $dom = $c->app->prepare_perldoc_html($variable_pod, $url_version, $pod_paths, 'variables', undef, $variable);
      $variables_dir->child($filename)->spew(encode 'UTF-8', $dom->to_string);
    }
  }
}

1;
