package PerldocBrowser::Command::purge;

# This software is Copyright (c) 2018 by Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
use Mojo::Base 'Mojolicious::Command';
use Mojo::URL;
use experimental 'signatures';

has description => 'Purge Fastly cache';
has usage => "Usage: $0 purge [all | <path> ...]\n";

sub run ($self, @paths) {
  die $self->usage unless @paths;
  my $api_key = $self->app->config('fastly_api_key') // die "No fastly_api_key configured\n";
  my %headers = (
    'Fastly-Key' => $api_key,
    Accept => 'application/json',
  );
  if ($paths[0] eq 'all') {
    my $service_id = $self->app->config('fastly_service_id') // die "No fastly_service_id configured\n";
    my $url = Mojo::URL->new('https://api.fastly.com')->path("/service/$service_id/purge_all");
    my $res = $self->app->ua->post($url, \%headers)->result;
    print $res->body, "\n";
  } else {
    foreach my $path (@paths) {
      my $url = Mojo::URL->new($path);
      unless (length $url->host) {
        my $host = $self->app->config('canonical_host') // die "No canonical_host configured\n";
        $url->scheme('https')->host($host);
      }
      my $res = $self->app->ua->start($self->app->ua->build_tx(PURGE => $url, \%headers))->result;
      print $res->body, "\n";
    }
  }
}

1;
