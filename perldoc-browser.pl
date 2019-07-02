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

if (@$all_versions) {
  foreach my $perl_version (@$all_versions) {
    my $v = app->warmup_version_object($perl_version);
    if ($perl_version eq 'blead' or $perl_version =~ m/-RC[0-9]+$/) {
      push @dev_versions, $perl_version;
    } elsif ($v < version->parse('v5.6.0') and ($v->{version}[2] // 0) >= 500) {
      push @dev_versions, $perl_version;
    } elsif ($v >= version->parse('v5.6.0') and ($v->{version}[1] // 0) % 2) {
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
  $inc_dirs{$current_version} = [@current_inc, File::Spec->catdir($Config{installprivlib}, 'pods'), $Config{scriptdir}];
}

helper all_perl_versions => sub ($c) { [@$all_versions] };

helper perl_versions => sub ($c) { [@perl_versions] };
helper dev_versions => sub ($c) { [@dev_versions] };

helper latest_perl_version => sub ($c) { $latest_version };

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
plugin 'PerldocInstall';

app->start;
