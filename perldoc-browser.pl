#!/usr/bin/env perl

# This software is Copyright (c) 2018 by Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
use Mojolicious::Lite;
use IPC::System::Simple 'capturex';
use Mojo::File 'path';
use Sort::Versions;
use version;
use experimental 'signatures';
use lib::relative 'lib';

push @{app->commands->namespaces}, 'PerldocBrowser::Command';
push @{app->plugins->namespaces}, 'PerldocBrowser::Plugin';

plugin Config => {file => 'perldoc-browser.conf', default => {}};

my $perls_dir = path(app->config->{perls_dir} // app->home->child('perls'));
helper perls_dir => sub ($c) { $perls_dir };

my $all_versions = -d $perls_dir ? $perls_dir->list({dir => 1})
  ->grep(sub { -d && -x path($_)->child('bin', 'perl') })
  ->map(sub { $_->basename })->sort(sub { versioncmp($b, $a) }) : [];
die "No perls found in $perls_dir\n" unless @$all_versions;

helper all_perl_versions => sub ($c) { [@$all_versions] };

my (@perl_versions, @dev_versions);
my $latest_version = app->config->{latest_perl_version};
foreach my $perl_version (@$all_versions) {
  my $v = eval { version->parse($perl_version =~ s/^perl-//r) };
  if (defined $v and $v->{version}[1] % 2) {
    push @dev_versions, $perl_version;
  } elsif ($perl_version eq 'blead' or $perl_version =~ m/-RC\d+$/) {
    push @dev_versions, $perl_version;
  } else {
    push @perl_versions, $perl_version;
    $latest_version //= $perl_version if defined $v;
  }
}

helper perl_versions => sub ($c) { [@perl_versions] };
helper dev_versions => sub ($c) { [@dev_versions] };

$latest_version //= $all_versions->first;

helper latest_perl_version => sub ($c) { $latest_version };

my %inc_dirs;
foreach my $perl_version (@$all_versions) {
  my $perl_bin = $perls_dir->child($perl_version, 'bin', 'perl');
  local $ENV{PERLLIB} = '';
  local $ENV{PERL5LIB} = '';
  $inc_dirs{$perl_version} = [grep { $_ ne '.' } split /\n+/, capturex $perl_bin, '-MConfig', '-e', 'print "$_\n" for @INC; print "$Config{scriptdir}\n"'];
}

helper inc_dirs => sub ($c, $perl_version) { $inc_dirs{$perl_version} // [] };

any '/#url_perl_version/contact' => {module => 'contact', perl_version => $latest_version, url_perl_version => ''}, sub ($c) {
  $c->stash(cpan => 'https://metacpan.org');
  $c->stash(perl_version => $c->stash('url_perl_version')) if $c->stash('url_perl_version');
  my $src = join "\n\n", @{$c->app->config->{contact_pod} // []};
  $c->respond_to(txt => {data => $src}, html => sub {
    $c->content_for(perldoc => $c->pod_to_html($src));
    $c->render('perldoc', title => 'contact', parts => []);
  });
};
plugin 'PerldocSearchPg' unless app->config->{no_search};
plugin 'PerldocRenderer';

app->start;
