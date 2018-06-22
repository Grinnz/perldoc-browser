package PerldocBrowser::Plugin::PerldocSearch;

# This software is Copyright (c) 2018 Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
use Mojo::Base 'Mojolicious::Plugin';
use Mojo::DOM;
use Mojo::URL;
use Mojo::Util qw(url_unescape trim);
use experimental 'signatures';

sub register ($self, $app, $conf) {
  $app->helper(index_pod => \&_index_pod);
  $app->helper(index_functions => \&_index_functions);
  $app->helper(clear_pod_index => \&_clear_pod_index);
  $app->helper(clear_function_index => \&_clear_function_index);

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
  $c->stash(cpan => Mojo::URL->new('https://metacpan.org/search')->query(q => $query));

  my $url_perl_version = $c->stash('url_perl_version');
  my $url_prefix = $url_perl_version ? "/$url_perl_version" : '';

  my $pod = _pod_name_match($c, $query);
  return $c->redirect_to("$url_prefix/$pod") if defined $pod;

  my $function = _function_name_match($c, $query);
  return $c->redirect_to("$url_prefix/functions/$function") if defined $function;

  my $pod_results = _pod_search($c, $query);

  my $function_results = _function_search($c, $query);

  my @paras = ('=head1 SEARCH RESULTS', 'B<>', '=head2 Functions', '=over');
  if (@$function_results) {
    push @paras, map { "=item L<perlfunc/$_->{name}>" } @$function_results;
  } else {
    push @paras, '=item I<No results>';
  }
  push @paras, '=back', '=head2 Pod', '=over';
  if (@$pod_results) {
    push @paras, map { "=item L<$_->{name}> - $_->{abstract}" } @$pod_results;
  } else {
    push @paras, '=item I<No results>';
  }
  push @paras, '=back';
  my $src = join "\n\n", @paras;

  my $dom = Mojo::DOM->new($c->pod_to_html($src, $url_perl_version));

  # Rewrite links to function pages
  for my $e ($dom->find('a[href]')->each) {
    next unless $e->attr('href') =~ /^[^#]+perlfunc#(.[^-]*)/;
    my $function = url_unescape "$1";
    $e->attr(href => Mojo::URL->new("$url_prefix/functions/$function"))->content($function);
  }

  # Combine everything to a proper response
  $c->content_for(perldoc => "$dom");
  $c->respond_to(txt => {data => $src}, html => sub { $c->render('perldoc', title => 'search', parts => []) });
}

sub _pod_name_match ($c, $query) {
  my $match = $c->pg->db->query('SELECT "name" FROM "pods" WHERE "perl_version" = ?
    AND lower("name") = lower(?) ORDER BY "name" LIMIT 1', $c->stash('perl_version'), $query)->arrays->first;
  return defined $match ? $match->[0] : undef;
}

sub _function_name_match ($c, $query) {
  my $match = $c->pg->db->query('SELECT "name" FROM "functions" WHERE "perl_version" = ?
    AND lower("name") = lower(?) ORDER BY "name" LIMIT 1', $c->stash('perl_version'), $query)->arrays->first;
  return defined $match ? $match->[0] : undef;
}

sub _pod_search ($c, $query) {
  return $c->pg->db->query(q{SELECT "name", "abstract",
    ts_rank_cd("indexed", plainto_tsquery('english', $1), 1) AS "rank"
    FROM "pods" WHERE "perl_version" = $2 AND "indexed" @@ plainto_tsquery('english', $1)
    ORDER BY "rank" DESC, "name"}, $query, $c->stash('perl_version'))->hashes;
}

sub _function_search ($c, $query) {
  return $c->pg->db->query(q{SELECT "name",
    ts_rank_cd("indexed", plainto_tsquery('english', $1), 1) AS "rank"
    FROM "functions" WHERE "perl_version" = $2 AND "indexed" @@ plainto_tsquery('english', $1)
    ORDER BY "rank" DESC, "name"}, $query, $c->stash('perl_version'))->hashes;
}

sub _index_pod ($c, $db, $perl_version, $name, $src) {
  my $dom = Mojo::DOM->new($c->pod_to_html($src));
  my $headings = $dom->find('h1');

  my $name_heading = $headings->first(sub { trim($_->all_text) eq 'NAME' });
  my $name_para = $name_heading ? $name_heading->following('p')->first : undef;
  my $abstract = '';
  if (defined $name_para) {
    $abstract = $name_para->all_text;
    $abstract =~ s/.*?\s+-\s+//;
  }

  my $description_heading = $headings->first(sub { trim($_->all_text) eq 'DESCRIPTION' })
    // $headings->first(sub { my $t = trim($_->all_text); $t ne 'NAME' and $t ne 'SYNOPSIS' });
  my $description_para = $description_heading ? $description_heading->following('p')->first : undef;
  my $description = $description_para ? $description_para->all_text : '';

  my $contents = $dom->all_text;

  $db->insert('pods', {
    perl_version => $perl_version,
    name => $name,
    abstract => trim($abstract),
    description => trim($description),
    contents => trim($contents),
  }, {on_conflict => \['("perl_version","name") do update set
    "abstract"=EXCLUDED."abstract", "description"=EXCLUDED."description",
    "contents"=EXCLUDED."contents"']}
  );
}

sub _index_functions ($c, $db, $perl_version, $src) {
  my $blocks = $c->split_functions($src);
  my %functions;
  foreach my $block (@$blocks) {
    my ($list_level, $is_filetest, @block_text, %names) = (0);
    foreach my $para (@$block) {
      $list_level++ if $para =~ m/^=over/;
      $list_level-- if $para =~ m/^=back/;
      # 0: navigatable, 1: navigatable and returned in search results
      unless ($list_level) {
        $names{"$1"} = 1 if $para =~ m/^=item ([-\w\/]+)/;
        $names{"$1"} //= 0 if $para =~ m/^=item ([-\w]+)/;
        $is_filetest = 1 if $para =~ m/^=item -X/;
      }
      do { $names{"$_"} //= 0 for $para =~ m/^\s+(-[a-zA-Z])\s/mg } if $is_filetest;
      push @block_text, $para if $list_level or $para !~ m/^=item/;
    }
    push @{$functions{$_}}, $names{$_} ? @block_text : () for keys %names;
  }

  foreach my $function (keys %functions) {
    my $pod = join "\n\n", '=over', @{$functions{$function}}, '=back';
    my $dom = Mojo::DOM->new($c->pod_to_html($pod));
    my $description = $dom->all_text;

    $db->insert('functions', {
      perl_version => $perl_version,
      name => $function,
      description => trim($description),
    }, {on_conflict => \['("perl_version","name") do update set
      "description"=EXCLUDED."description"']}
    );
  }
}

sub _clear_pod_index ($c, $db, $perl_version) {
  $db->delete('pods', {perl_version => $perl_version});
}

sub _clear_function_index ($c, $db, $perl_version) {
  $db->delete('functions', {perl_version => $perl_version});
}

1;
