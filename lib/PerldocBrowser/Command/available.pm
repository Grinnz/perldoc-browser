package PerldocBrowser::Command::available;

use Mojo::Base 'Mojolicious::Command', -signatures;
use Mojo::Util qw(getopt);
use CPAN::Perl::Releases::MetaCPAN;
use List::Util qw(all);
use version    ();

has description => 'Install released or trial versions of perl that are available';
has usage       => sub { shift->extract_usage };

sub run ($self, @args) {
  my $opt_ok = getopt \@args,
    'd|dry-run'      => \my $dry,
    'l|latest-only'  => \my $latest_only,
    'n|newer-than=s' => \my $oldest,
    't|trial'        => \my $include_trial;

  $self->app->warmup_perl_versions;
  my $installed_versions = {map { $self->app->perl_version_object($_)->normal => $_ } @{$self->app->all_perl_versions}};
  $oldest ||= $self->app->latest_perl_version;
  $self->app->log->info("Searching for perls newer than @{[version->declare($oldest)->normal]}");

  my @predicates;
  my $cpan_latest = qr/(?:cpan|latest)/;
  push @predicates, sub { $_->{status} =~ m/$cpan_latest/ };

  push @predicates, sub { $_->{maturity} eq 'released' }
    unless $include_trial;

  push @predicates, sub { version->parse($_->{version}) > version->declare($oldest) };

  push @predicates, sub {    # is the version already installed - care taken WRT trial version names
    my $v                 = version->parse($_->{version});
    my $version_installed = exists($installed_versions->{$v->normal});
    return !($_->{name} eq join '-', 'perl', $installed_versions->{$v->normal}) if $version_installed;
    return !$version_installed;
  };

  my @discovered_versions = map { $_->{name} =~ s/^perl-//r }
    sort { version->parse($b->{version}) <=> version->parse($a->{version}) } _available_perls(\@predicates)->@*;
  return unless @discovered_versions;
  @discovered_versions = shift @discovered_versions if $latest_only;
  $self->app->log->info($_) for @discovered_versions;
  $self->app->commands->run(install => @discovered_versions) unless $dry;
}

sub _available_perls ($predicates) {
  return _filter($predicates, CPAN::Perl::Releases::MetaCPAN->new->get || []);
}

sub _filter ($predicates, $arrayref) {
  my $_call = sub ($func, $param) { !!($func->(local $_ = $param)) };
  return [
    map { $_->[0] }    # actual item
    grep {
      all { !!$_ }     # all have to be true
        @$_
    } map {
      my $x = $_;
      [$x, map { $_->$_call($x) } @$predicates]
    } @$arrayref
  ];
}

1;

=encoding utf8

=head1 NAME

available - retrieve a list of available/uninstalled perls and install them

=head1 SYNOPSIS

  Usage: APPLICATION available [options]

    perldoc-browser.pl available -d
    perldoc-browser.pl available -l
    perldoc-browser.pl available -n 5.38.1

  Options:
    -d, --dry-run               Do not install anything, just log the perl versions to install
    -h, --help                  Show this help
    -l, --latest-only           Select only the most recent version for installation
    -n, --newer-than <version>  Include only versions newer than version for installation
    -t, --trial                 Include developer/trial versions for installation

=cut
