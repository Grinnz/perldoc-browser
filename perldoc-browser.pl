#!/usr/bin/env perl

# This software is Copyright (c) 2018 by Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
my @current_inc;
BEGIN { @current_inc = grep { !ref and $_ ne '.' } @INC }

use Mojolicious::Lite;
use Config;
use File::Basename 'fileparse';
use File::Copy;
use File::Path 'make_path';
use File::Spec;
use File::Temp;
use IPC::Run3;
use List::Util 'first';
use Mojo::File 'path';
use Mojo::Util qw(dumper trim);
use Sort::Versions;
use version;
use experimental 'signatures';
use lib::relative 'lib';

app->attr('search_backend');

push @{app->commands->namespaces}, 'PerldocBrowser::Command';
push @{app->plugins->namespaces}, 'PerldocBrowser::Plugin';

plugin Config => {file => 'perldoc-browser.conf', default => {}};

if (defined(my $logfile = app->config->{logfile})) {
  app->log->with_roles('+Clearable')->path($logfile);
}

my $perls_dir = path(app->config->{perls_dir} // app->home->child('perls'));
helper perls_dir => sub ($c) { $perls_dir };

my $all_versions = [];
$all_versions = $perls_dir->list({dir => 1})
  ->grep(sub { -d && -x path($_)->child('bin', 'perl') })
  ->map(sub { $_->basename })
  ->sort(sub { versioncmp($b, $a) }) if -d $perls_dir;

my (@perl_versions, @dev_versions);
my $latest_version = app->config->{latest_perl_version};

my %inc_dirs;
helper warmup_inc_dirs => sub ($c, $perl_version) {
  my $bin = $c->perls_dir->child($perl_version, 'bin', 'perl');
  local $ENV{PERLLIB} = '';
  local $ENV{PERL5LIB} = '';
  local $ENV{PERL5OPT} = '';
  run3 [$bin, '-MConfig', '-e', 'print "$_\n" for @INC; print "$Config{scriptdir}\n"'], undef, \my @output;
  my $exit = $? >> 8;
  die "Failed to retrieve include directories for $bin (exit $exit)\n" if $exit;
  chomp @output;
  return $inc_dirs{$perl_version} = [grep { length $_ && $_ ne '.' } @output];
};
helper inc_dirs => sub ($c, $perl_version) { $inc_dirs{$perl_version} // [] };

if (@$all_versions) {
  foreach my $perl_version (@$all_versions) {
    my $v = eval { version->parse($perl_version =~ s/^perl-//r) };
    if (defined $v and $v < version->parse('v5.6.0') and ($v->{version}[2] // 0) >= 500) {
      push @dev_versions, $perl_version;
    } elsif (defined $v and $v >= version->parse('v5.6.0') and ($v->{version}[1] // 0) % 2) {
      push @dev_versions, $perl_version;
    } elsif ($perl_version eq 'blead' or $perl_version =~ m/-RC\d+$/) {
      push @dev_versions, $perl_version;
    } else {
      push @perl_versions, $perl_version;
      $latest_version //= $perl_version if defined $v;
    }
    app->warmup_inc_dirs($perl_version);
  }
  $latest_version //= $all_versions->first;
} else {
  my $current_version = $Config{version};
  ($Config{PERL_VERSION} % 2) ? (push @dev_versions, $current_version) : (push @perl_versions, $current_version);
  push @$all_versions, $current_version;
  $latest_version //= $current_version;
  $inc_dirs{$current_version} = [@current_inc, $Config{scriptdir}];
}

helper all_perl_versions => sub ($c) { [@$all_versions] };

helper perl_versions => sub ($c) { [@perl_versions] };
helper dev_versions => sub ($c) { [@dev_versions] };

helper latest_perl_version => sub ($c) { $latest_version };

helper missing_core_modules => sub ($c, $inc_dirs) {
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
};

helper download_perl_extracted => sub ($c, $perl_version, $dir) {
  require CPAN::Perl::Releases;
  require HTTP::Tiny;

  my ($url, $tarball);
  if ($perl_version eq 'blead') {
    $tarball = 'blead.tar.gz';
    $url = 'https://perl5.git.perl.org/perl.git/snapshot/blead.tar.gz';
  } else {
    my $releases = CPAN::Perl::Releases::perl_tarballs($perl_version =~ s/^perl-//r);
    die "Could not find release of Perl version $perl_version\n"
      unless defined $releases and defined $releases->{'tar.gz'};

    $tarball = $releases->{'tar.gz'} =~ s!.*/!!r;
    $url = "https://cpan.metacpan.org/authors/id/$releases->{'tar.gz'}";
  }
  my $tarpath = File::Spec->catfile($dir, $tarball);
  my $http = HTTP::Tiny->new(verify_SSL => 1);
  my $response = $http->mirror($url, $tarpath);
  unless ($response->{success}) {
    my $msg = $response->{status} == 599 ? ", $response->{content}" : "";
    chomp $msg;
    die "Failed to download $url: $response->{status} $response->{reason}$msg\n";
  }

  my $output;
  run3 ['tar', '-C', $dir, '-xzf', $tarpath], undef, \$output, \$output;
  my $exit = $? >> 8;
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
};

my %dist_name_override = (
  'Sys::Syslog::Win32' => 'Sys-Syslog',
  'Sys::Syslog::win32::Win32' => 'Sys-Syslog',
);

helper copy_modules_from_source => sub ($c, $perl_version, @modules) {
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
    my $pm = pop(@parts) . '.pm';
    next if -e File::Spec->catfile($privlib, @parts, $pm);
    my $distdir = first { -d } (map { File::Spec->catdir($build, $_, $dist_name) } qw(ext cpan dist)),
      File::Spec->catdir($build, 'ext', split /-/, $dist_name);
    my $source_path;
    if (defined $distdir) {
      $source_path = first { -e } File::Spec->catfile($distdir, $pm),
        File::Spec->catfile($distdir, 'lib', @parts, $pm);
      if (!defined $source_path) {
        my $lib_path;
        if ($module eq 'Sys::Syslog::Win32' or $module eq 'Sys::Syslog::win32::Win32') {
          $lib_path = File::Spec->catfile($distdir, 'win32', $pm);
        }
        $source_path = $lib_path if -e $lib_path;
      }
    } else {
      my $lib_path = File::Spec->catfile($build, 'lib', @parts, $pm);
      $source_path = $lib_path if -e $lib_path;
    }
    unless (defined $source_path) {
      warn "File $pm not found for module $module\n";
      next;
    }
    make_path(File::Spec->catdir($privlib, @parts)) if @parts;
    copy($source_path, File::Spec->catfile($privlib, @parts, $pm))
      or die "Failed to copy $source_path to $privlib: $!";
    print "Copied $module ($source_path) to $privlib\n";
  }
};

my $csp = join '; ',
  q{default-src 'self'},
  q{connect-src 'self' www.google-analytics.com},
  q{img-src 'self' data: www.google-analytics.com www.googletagmanager.com},
  q{script-src 'self' 'unsafe-inline' cdnjs.cloudflare.com code.jquery.com stackpath.bootstrapcdn.com www.google-analytics.com www.googletagmanager.com},
  q{style-src 'self' 'unsafe-inline' cdnjs.cloudflare.com stackpath.bootstrapcdn.com},
  q{report-uri /csp-reports};

hook after_render => sub ($c, @) { $c->res->headers->content_security_policy($csp) };

post '/csp-reports' => sub ($c) {
  if (defined(my $violation = $c->req->json)) {
    my $serialized = dumper $violation;
    $c->app->log->error("CSP violation: $serialized");
  }
  $c->render(data => '');
};

any '/#url_perl_version/contact' => {module => 'contact', perl_version => $latest_version, url_perl_version => ''}, sub ($c) {
  $c->stash(page_name => 'contact');
  $c->stash(cpan => 'https://metacpan.org');
  $c->stash(perl_version => $c->stash('url_perl_version')) if $c->stash('url_perl_version');
  my $src = join "\n\n", @{$c->app->config->{contact_pod} // []};
  $c->content_for(perldoc => $c->pod_to_html($src));
  $c->render('perldoc', title => 'contact');
};

any '/opensearch';

plugin 'PerldocSearch';
plugin 'PerldocRenderer';

app->start;
