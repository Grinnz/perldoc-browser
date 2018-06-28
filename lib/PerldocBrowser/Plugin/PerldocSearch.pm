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
  $app->helper(clear_index => \&_clear_index);

  my %defaults = (
    module => 'search',
    perl_version => $app->latest_perl_version,
    url_perl_version => '',
  );

  foreach my $perl_version (@{$app->all_perl_versions}) {
    $app->routes->any("/$perl_version/search" => {%defaults, perl_version => $perl_version, url_perl_version => $perl_version} => \&_search);
  }

  $app->routes->any('/search' => {%defaults} => \&_search);
}

sub _search ($c) {
  my $query = trim($c->param('q') // '');
  $c->stash(cpan => Mojo::URL->new('https://metacpan.org/search')->query(q => $query));

  my $url_perl_version = $c->stash('url_perl_version');
  my $url_prefix = $url_perl_version ? "/$url_perl_version" : '';

  my $function = _function_name_match($c, $query);
  return $c->redirect_to("$url_prefix/functions/$function") if defined $function;

  my $pod = _pod_name_match($c, $query);
  return $c->redirect_to("$url_prefix/$pod") if defined $pod;

  my $function_results = _function_search($c, $query);
  my $pod_results = _pod_search($c, $query);

  my @paras = ('=encoding UTF-8', '=head1 SEARCH RESULTS', 'B<>', '=head2 Functions', '=over');
  if (@$function_results) {
    foreach my $function (@$function_results) {
      my $name = _escape_pod($function->{name});
      my $headline = $function->{headline} =~ s/\n+/ /gr;
      push @paras, "=item L<perlfunc/$name>\n\n$headline";
    }
  } else {
    push @paras, '=item I<No results>';
  }
  push @paras, '=back', '=head2 Pod', '=over';
  if (@$pod_results) {
    foreach my $page (@$pod_results) {
      my ($name, $abstract) = map { _escape_pod($_) } @$page{'name','abstract'};
      my $headline = $page->{headline} =~ s/\n+/ /gr;
      push @paras, "=item L<$name> - $abstract\n\n$headline";
    }
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

my %escapes = ('<' => 'lt', '>' => 'gt', '|' => 'verbar', '/' => 'sol');
sub _escape_pod ($text) {
  return $text =~ s/([<>|\/])/E<$escapes{$1}>/gr;
}

sub _pod_name_match ($c, $query) {
  my $match = $c->pg->db->query('SELECT "name" FROM "pods" WHERE "perl_version" = $1
    AND lower("name") = lower($2) ORDER BY "name" = $2 DESC, "name" LIMIT 1', $c->stash('perl_version'), $query)->arrays->first;
  return defined $match ? $match->[0] : undef;
}

sub _function_name_match ($c, $query) {
  my $match = $c->pg->db->query('SELECT "name" FROM "functions" WHERE "perl_version" = $1
    AND lower("name") = lower($2) ORDER BY "name" = $2 DESC, "name" LIMIT 1', $c->stash('perl_version'), $query)->arrays->first;
  return defined $match ? $match->[0] : undef;
}

my $headline_opts = 'StartSel="I<<< B<< ", StopSel=" >> >>>", MaxWords=15, MinWords=10, MaxFragments=2';
sub _pod_search ($c, $query) {
  return $c->pg->db->query(q{SELECT "name", "abstract",
    ts_rank_cd("indexed", plainto_tsquery('english', $1), 1) AS "rank",
    ts_headline('english', "contents", plainto_tsquery('english', $1), $2) AS "headline"
    FROM "pods" WHERE "perl_version" = $3 AND "indexed" @@ plainto_tsquery('english', $1)
    ORDER BY "rank" DESC, "name" LIMIT 20}, $query, $headline_opts, $c->stash('perl_version'))->hashes;
}

sub _function_search ($c, $query) {
  return $c->pg->db->query(q{SELECT "name",
    ts_rank_cd("indexed", plainto_tsquery('english', $1), 1) AS "rank",
    ts_headline('english', "name" || ' - ' || "description", plainto_tsquery('english', $1), $2) AS "headline"
    FROM "functions" WHERE "perl_version" = $3 AND "indexed" @@ plainto_tsquery('english', $1)
    ORDER BY "rank" DESC, "name" LIMIT 20}, $query, $headline_opts, $c->stash('perl_version'))->hashes;
}

sub _index_pod ($c, $db, $perl_version, $name, $src) {
  my %properties = (perl_version => $perl_version, name => $name, abstract => '', description => '', contents => '');

  unless ($name eq 'perltoc') {
    my $dom = Mojo::DOM->new($c->pod_to_html($src));
    my $headings = $dom->find('h1');

    my $name_heading = $headings->first(sub { trim($_->all_text) eq 'NAME' });
    my $name_para = $name_heading ? $name_heading->following('p')->first : undef;
    if (defined $name_para) {
      $properties{abstract} = trim($name_para->all_text);
      $properties{abstract} =~ s/.*?\s+-\s+//;
    }

    my $description_heading = $headings->first(sub { trim($_->all_text) eq 'DESCRIPTION' })
      // $headings->first(sub { my $t = trim($_->all_text); $t ne 'NAME' and $t ne 'SYNOPSIS' });
    my $description_para = $description_heading ? $description_heading->following('p')->first : undef;
    $properties{description} = trim($description_para->all_text) if $description_para;

    $properties{contents} = trim($dom->all_text);
  }

  $db->insert('pods', \%properties, {on_conflict => \['("perl_version","name")
    do update set "abstract"=EXCLUDED."abstract", "description"=EXCLUDED."description",
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
        $names{"$1"} = 1 if $para =~ m/^=item (?:I<)?([-\w\/]+)/;
        $names{"$1"} //= 0 if $para =~ m/^=item (?:I<)?([-\w]+)/;
        $is_filetest = 1 if $para =~ m/^=item (?:I<)?-X/;
      }
      do { $names{"$_"} //= 0 for $para =~ m/^\s+(-[a-zA-Z])\s/mg } if $is_filetest;
      push @block_text, $para if $list_level or $para !~ m/^=item/;
    }
    push @{$functions{$_}}, $names{$_} ? @block_text : () for keys %names;
  }

  foreach my $function (keys %functions) {
    my $pod = join "\n\n", '=over', @{$functions{$function}}, '=back';
    my $dom = Mojo::DOM->new($c->pod_to_html($pod));
    my $description = trim($dom->all_text);

    $db->insert('functions', {
      perl_version => $perl_version,
      name => $function,
      description => $description,
    }, {on_conflict => \['("perl_version","name") do update set
      "description"=EXCLUDED."description"']}
    );
  }
}

sub _index_variables ($c, $db, $perl_version, $src) {
  my $blocks = $c->split_variables($src);
  my %variables;
  foreach my $block (@$blocks) {
    my ($list_level, @block_text, %names) = (0);
    foreach my $para (@$block) {
      $list_level++ if $para =~ m/^=over/;
      $list_level-- if $para =~ m/^=back/;
      # 0: navigatable, 1: navigatable and returned in search results
      unless ($list_level) {
        if ($para =~ m/^=item \$<I<digits>>([^\n]+)/) {
          $names{"\$<digits>$1"} = 1;
          $names{"\$$_"} = 0 for 1..9;
        } else {
          $names{"$1"} = 1 if $para =~ m/^=item ([\$\@%]\S+)/;
        }
      }
      push @block_text, $para if $list_level or $para !~ m/^=item/;
    }
    push @{$variables{$_}}, $names{$_} ? @block_text : () for keys %names;
  }

  foreach my $variable (keys %variables) {
    my $pod = join "\n\n", '=over', @{$variables{$variable}}, '=back';
    my $dom = Mojo::DOM->new($c->pod_to_html($pod));
    my $description = trim($dom->all_text);

    $db->insert('variables', {
      perl_version => $perl_version,
      name => $variable,
      description => $description,
    }, {on_conflict => \['("perl_version","name") do update set
      "description"=EXCLUDED."description"']}
    );
  }
}

sub _clear_index ($c, $db, $perl_version, $type) {
  $db->delete($type, {perl_version => $perl_version});
}

1;
