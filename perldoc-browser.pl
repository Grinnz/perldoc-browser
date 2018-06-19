#!/usr/bin/env perl

# This software is Copyright (c) 2018 by Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
use Mojolicious::Lite;
use Mojo::File 'path';
use Sort::Versions;
use version;
use lib::relative 'lib';

push @{app->commands->namespaces}, 'PerldocBrowser::Command';
push @{app->plugins->namespaces}, 'PerldocBrowser::Plugin';

plugin Config => {file => 'perldoc-browser.conf', default => {}};

my $perls_dir = path(app->config->{perls_dir} // app->home->child('perls'));
my $perl_versions = -d $perls_dir ? $perls_dir->list({dir => 1})
  ->grep(sub { -d && -x path($_)->child('bin', 'perl') })
  ->map(sub { $_->basename })->sort(sub { versioncmp($b, $a) }) : [];
die "No perls found in $perls_dir\n" unless @$perl_versions;

my (@stable_versions, @dev_versions);
my $latest_version = app->config->{latest_perl_version};
foreach my $perl_version (@$perl_versions) {
  my $v = eval { version->parse($perl_version =~ s/^perl-//r) };
  if (defined $v and $v->{version}[1] % 2) {
    push @dev_versions, $perl_version;
  } else {
    push @stable_versions, $perl_version;
    $latest_version //= $perl_version if defined $v;
  }
}

$latest_version //= $perl_versions->first;

plugin PerldocRenderer => {
  perl_versions => \@stable_versions,
  dev_versions => \@dev_versions,
  latest_version => $latest_version,
  perls_dir => $perls_dir,
};

app->start;
