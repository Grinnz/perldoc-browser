package PerldocBrowser::Plugin::PerldocSearch;

# This software is Copyright (c) 2018 Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
use Mojo::Base 'Mojolicious::Plugin';
use Mojo::DOM;
use Mojo::File 'path';
use experimental 'signatures';

sub register ($self, $app, $conf) {
  $app->helper(index_pod => \&_index_pod);

  my $perl_versions = $app->perl_versions;
  my $dev_versions = $app->dev_versions;

  my %defaults = (
    perl_versions => $perl_versions,
    dev_perl_versions => $dev_versions,
    module => 'search',
    perl_version => $app->latest_perl_version,
    url_perl_version => '',
  );

  foreach my $perl_version (@$perl_versions, @$dev_versions) {
    $app->routes->any("/$perl_version/search" => {%defaults, perl_version => $perl_version, url_perl_version => $perl_version} => \&_search);
  }
  $app->routes->any('/search' => {%defaults} => \&_search);
}

sub _search ($c) {
  my $query = $c->param('q') // '';

  my $url_perl_version = $c->stash('url_perl_version');
  my $prefix = $url_perl_version ? "/$url_perl_version" : '';

  my $page = _pod_name_match($c, $query);
  return $c->redirect_to("$prefix/$page") if defined $page;

  my $function = _function_name_match($c, $query);
  return $c->redirect_to("$prefix/functions/$function") if defined $function;

  return $c->reply->not_found;
}

sub _pod_name_match ($c, $query) {
  my $match = $c->pg->db->query('SELECT "name" FROM "pods" WHERE "perl_version" = ?
    AND lower("name") = lower(?) ORDER BY "name" LIMIT 1', $c->stash('perl_version'), $query)->arrays->first;
  return defined $match ? $match->[0] : undef;
}

sub _function_name_match ($c, $query) {
  my $match = $c->pg->db->query('SELECT "name" FROM "functions" WHERE "perl_version" = ?
    AND lower("name") = lower(?) ORDER BY "name" LIMIT 1', $c->stash('perl_version'), $query)->arrays->first;
}

sub _index_pod ($c, $db, $perl_version, $name, $path) {
  my $dom = Mojo::DOM->new($c->pod_to_html(path($path)->slurp));
  my $headings = $dom->find('h1');

  my $name_heading = $headings->first(sub { $_->all_text eq 'NAME' });
  my $name_para = $name_heading ? $name_heading->following('p')->first : undef;
  my $abstract = '';
  if (defined $name_para) {
    $abstract = $name_para->all_text;
    $abstract =~ s/.*?\s+-\s+//;
  }

  my $description_heading = $headings->first(sub { $_->all_text eq 'DESCRIPTION' })
    // $headings->first(sub { my $t = $_->all_text; $t ne 'NAME' and $t ne 'SYNOPSIS' });
  my $description_para = $description_heading ? $description_heading->following('p')->first : undef;
  my $description = $description_para ? $description_para->all_text : '';

  my $contents = $dom->all_text;

  $db->insert('pods', {
    perl_version => $perl_version,
    name => $name,
    abstract => $abstract,
    description => $description,
    contents => $contents,
  }, {on_conflict => \['("perl_version","name") do update set
    "abstract"=EXCLUDED."abstract", "description"=EXCLUDED."description",
    "contents"=EXCLUDED."contents"']}
  );
}

1;
