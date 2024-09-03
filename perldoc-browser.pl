#!/usr/bin/env perl

# This software is Copyright (c) 2018 by Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
my @current_inc;
BEGIN { @current_inc = grep { !ref and $_ ne '.' } @INC }

use Mojolicious::Lite;
use Config;
use File::Spec;
use IPC::Run3;
use Mojo::File 'path';
use Mojo::Util 'dumper';
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

my %inc_dirs;
helper warmup_inc_dirs => sub ($c, $perl_version) {
  my $bin = $c->perls_dir->child($perl_version, 'bin', 'perl');
  local $ENV{PERLLIB} = '';
  local $ENV{PERL5LIB} = '';
  local $ENV{PERL5OPT} = '';
  # Regular @INC dirs, $installprivlib/pod will be included by Pod::Simple::Search
  # $installprivlib/pods is used on some architectures
  # scriptdir is not automatically included when specifying dirs
  run3 [$bin, '-MConfig', '-MFile::Spec', '-e',
    'print "$_\n" for @INC, File::Spec->catdir($Config{installprivlib}, "pods"), $Config{scriptdir}'], undef, \my @output;
  my $exit = $? >> 8;
  die "Failed to retrieve include directories for $bin (exit $exit)\n" if $exit;
  chomp @output;
  return $inc_dirs{$perl_version} = [grep { length $_ && $_ ne '.' } @output];
};
helper inc_dirs => sub ($c, $perl_version) { $inc_dirs{$perl_version} // [] };

my %version_objects;
helper warmup_version_object => sub ($c, $perl_version) {
  my $bin = $c->perls_dir->child($perl_version, 'bin', 'perl');
  local $ENV{PERL5OPT} = '';
  run3 [$bin, '-e', 'print "$]\n"'], undef, \my $output;
  chomp $output;
  return $version_objects{$perl_version} = version->parse($output);
};
helper perl_version_object => sub ($c, $perl_version) { $version_objects{$perl_version} };

my %function_descriptions;
helper warmup_function_descs => sub ($c, $perl_version) {
  my $bin = $c->perls_dir->child($perl_version, 'bin', 'perl');
  local $ENV{PERL5OPT} = '';
  run3 [$bin, '-MPod::Functions', '-e', 'print "$_ $Flavor{$_}\n" for sort keys %Flavor'], undef, \my @output;
  chomp @output;
  my (@function_names, %descriptions);
  foreach my $line (@output) {
    my ($name, $desc) = split ' ', $line, 2;
    push @function_names, $name;
    $descriptions{$name} = $desc;
  }
  return $function_descriptions{$perl_version} = {names => \@function_names, descriptions => \%descriptions};
};
helper function_names => sub ($c, $perl_version) { $function_descriptions{$perl_version}{names} };
helper function_descriptions => sub ($c, $perl_version) { $function_descriptions{$perl_version}{descriptions} };
helper function_description => sub ($c, $perl_version, $name) { $function_descriptions{$perl_version}{descriptions}{$name} };

my $perls_dir = path(app->config->{perls_dir} // app->home->child('perls'));
helper perls_dir => sub ($c) { $perls_dir };

my (@all_versions, @perl_versions, @dev_versions, %version_is_dev, $latest_version);
helper warmup_perl_versions => sub ($c) {
  @all_versions = -d $c->perls_dir ? $c->perls_dir->list({dir => 1})
    ->grep(sub { -d && -x path($_)->child('bin', 'perl') })
    ->map(sub { $_->basename })
    ->sort(sub { versioncmp($b, $a) })->each : ();

  (@perl_versions, @dev_versions, %version_is_dev) = ();
  $latest_version = app->config->{latest_perl_version};
  if (@all_versions) {
    foreach my $perl_version (@all_versions) {
      my $v = app->warmup_version_object($perl_version);
      if ($perl_version eq 'blead' or $perl_version =~ m/-RC[0-9]+$/
          or ($v < version->parse('v5.6.0') and ($v->{version}[2] // 0) >= 500)
          or ($v >= version->parse('v5.6.0') and ($v->{version}[1] // 0) % 2)) {
        push @dev_versions, $perl_version;
        $version_is_dev{$perl_version} = 1;
      } else {
        push @perl_versions, $perl_version;
        $version_is_dev{$perl_version} = 0;
        $latest_version //= $perl_version if defined $v;
      }
      app->warmup_inc_dirs($perl_version);
      app->warmup_function_descs($perl_version);
    }
    $latest_version //= $all_versions[0];
  } else {
    my $current_version = $Config{version};
    if ($Config{PERL_VERSION} % 2) {
      push @dev_versions, $current_version;
      $version_is_dev{$current_version} = 1;
    } else {
      push @perl_versions, $current_version;
      $version_is_dev{$current_version} = 0;
    }
    @all_versions = $current_version;
    $latest_version //= $current_version;
    $inc_dirs{$current_version} = [@current_inc, File::Spec->catdir($Config{installprivlib}, 'pods'), $Config{scriptdir}];
    if (eval { require Pod::Functions; 1 }) {
      my @function_names = sort keys %Pod::Functions::Flavor;
      my %descriptions = map { ($_ => $Pod::Functions::Flavor{$_}) } @function_names;
      $function_descriptions{$current_version} = {names => \@function_names, descriptions => \%descriptions};
    }
  }
};

helper all_perl_versions => sub ($c) { [@all_versions] };

helper perl_versions => sub ($c) { [@perl_versions] };
helper dev_versions => sub ($c) { [@dev_versions] };

helper latest_perl_version => sub ($c) { $latest_version };

helper perl_version_is_dev => sub ($c, $perl_version) { $version_is_dev{$perl_version} };

app->warmup_perl_versions;

my $csp = join '; ',
  q{default-src 'self'},
  q{connect-src 'self' *.google-analytics.com},
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

any '/opensearch' => [format => ['xml']];

plugin 'PerldocSearch';
plugin 'PerldocRenderer';
plugin 'PerldocInstall';

# needs renderer helpers available
my $footer_src = join "\n\n", '=encoding utf8', @{app->config->{footer_pod} // app->config->{contact_pod} // []};
my $footer_html = app->pod_to_html($footer_src);
helper footer_html => sub ($c) { $footer_html };

app->start;
