package PerldocBrowser::Plugin::PerldocRenderer;

# This software is Copyright (c) 2008-2018 Sebastian Riedel and others, 2018 Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
use Mojo::Base 'Mojolicious::Plugin';
use Lingua::EN::Sentence 'get_sentences';
use List::Util 'first';
use MetaCPAN::Pod::HTML;
use Module::Metadata;
use Mojo::ByteStream;
use Mojo::DOM;
use Mojo::File 'path';
use Mojo::URL;
use Mojo::Util qw(decode encode sha1_sum trim url_unescape);
use Pod::Simple::Search;
use Pod::Simple::TextContent;
use Scalar::Util 'weaken';
use experimental 'signatures';

{
  my %indexes = (
    index => {
      module => 'index',
      pod_source => 'perl',
      page_name => 'Perl Documentation',
      cpan => 'https://metacpan.org/pod/perl',
    },
    functions => {
      module => 'functions',
      pod_source => 'perlfunc',
      page_name => 'Perl builtin functions',
      cpan => 'https://metacpan.org/pod/perlfunc',
    },
    variables => {
      module => 'variables',
      pod_source => 'perlvar',
      page_name => 'Perl predefined variables',
      cpan => 'https://metacpan.org/pod/perlvar',
    },
    modules => {
      module => 'modules',
      pod_source => 'perlmodlib',
      page_name => 'Perl core modules',
      cpan => 'https://metacpan.org',
    },
  );

  sub _index_pages () { [sort keys %indexes] }

  sub _index_stash ($page) {
    my $index = $indexes{$page} // return undef;
    return {%$index};
  }
}

sub register ($self, $app, $conf) {
  $app->helper(split_functions => sub ($c, @args) { _split_functions(@args) });
  $app->helper(split_variables => sub ($c, @args) { _split_variables(@args) });
  $app->helper(split_faqs => sub ($c, @args) { _split_faqs(@args) });
  $app->helper(split_perldelta => sub ($c, @args) { _split_perldelta(@args) });
  $app->helper(pod_to_html => sub ($c, @args) { _pod_to_html(@args) });
  $app->helper(pod_to_text_content => sub ($c, @args) { _pod_to_text_content(@args) });
  $app->helper(escape_pod => sub ($c, @args) { _escape_pod(@args) });
  $app->helper(append_url_path => sub ($c, @args) { _append_url_path(@args) });
  $app->helper(current_doc_path => \&_current_doc_path);
  $app->helper(prepare_perldoc_html => \&_prepare_html);
  $app->helper(render_perldoc_html => \&_render_html);
  $app->helper(index_pages => sub ($c, @args) { _index_pages(@args) });
  $app->helper(index_stash => sub ($c, @args) { _index_stash(@args) });
  $app->helper(index_page => \&_index_page);
  $app->helper(function_pod_page => \&_function_pod_page);
  $app->helper(variable_pod_page => \&_variable_pod_page);
  $app->helper(cache_perl_to_html => \&_cache_perl_to_html);

  # canonicalize without .html
  my $r = $app->routes->under(sub ($c) {
    if ($c->req->url->path =~ m/\.html\z/i) {
      my $url = $c->url_with->to_abs;
      $url->path->[-1] =~ s/\.html\z//i if @{$url->path};
      $c->res->code(301);
      $c->redirect_to($url);
      return 0;
    }
    return 1;
  });

  my $homepage = $app->config('homepage') // 'index';
  my $latest_perl_version = $app->latest_perl_version;

  foreach my $perl_version (@{$app->all_perl_versions}, '') {
    my $versioned = $r->any("/$perl_version" => [format => ['html', 'txt']])->to(
      module => $homepage,
      perl_version => length $perl_version ? $perl_version : $latest_perl_version,
      url_perl_version => $perl_version,
      format => undef, # format extension optional
    );

    # individual function and variable pages
    # functions may contain / but not .
    $versioned->any('/functions/:function' => {module => 'functions'}
      => [function => qr/[^.]+/] => \&_function);
    # variables may contain /, and . only in the cases of $. and $<digits> ($1, $2, ...)
    $versioned->any('/variables/:variable' => {module => 'variables'}
      => [variable => qr/[^.]+(?:\.{3}[^.]+|\.)?/] => \&_variable);

    # index pages
    if (defined(my $index_stash = $app->index_stash($homepage))) {
      $versioned->any('/' => {%$index_stash, current_doc_path => '/'} => \&_index);
    } else {
      $versioned->any('/' => {module => $homepage, current_doc_path => '/'} => \&_perldoc);
    }
    $versioned->any("/$_" => $app->index_stash($_) => \&_index) for @{$app->index_pages};

    # all other docs
    # allow .pl for perl5db.pl and .pl scripts
    # allow / for legacy compatibility - redirected to ::
    $versioned->any('/:module' => [format => ['html', 'txt', 'pl'], module => qr/[^.]+/] => \&_perldoc);
  }
}

sub _current_doc_path ($c) {
  my $path = $c->stash('current_doc_path');
  unless (defined $path) {
    $path = $c->append_url_path('/', $c->stash('module'));
    my $subtarget = $c->stash('function') // $c->stash('variable');
    $path = $c->append_url_path($path, $subtarget) if defined $subtarget;
    $c->stash(current_doc_path => $path = $path->to_string);
  }
  return $path;
}

sub _find_pod ($c, $perl_version, $module) {
  my $inc_dirs = $c->inc_dirs($perl_version);
  my $path = Pod::Simple::Search->new->inc(0)->find($module, @$inc_dirs);
  return undef unless defined $path and -r $path;
  return $path;
}

sub _find_html ($c, $url_perl_version, $perl_version, @parts) {
  my $version = length $url_perl_version ? $url_perl_version : "latest-$perl_version";
  my $filename = sha1_sum(encode 'UTF-8', pop @parts) . '.html';
  my $path = $c->app->home->child('html', $version, @parts, $filename);
  return -r $path ? $path : undef;
}

sub _find_module ($c, $perl_version, $module) {
  my $inc_dirs = $c->inc_dirs($perl_version);
  my $meta;
  { local $@;
    $c->app->log->debug("Error retrieving module metadata for $module: $@")
      unless eval { $meta = Module::Metadata->new_from_module($module, inc => $inc_dirs); 1 };
  }
  return $meta;
}

my %perlglossary_anchors = (
  buffered        => 'buffer',
  compiled        => 'compile',
  captured        => 'capturing',
  casemaps        => 'case',
  dereferencing   => 'dereference',
  destroying      => 'destroy',
  directories     => 'directory',
  'dynamic scope' => 'dynamic-scoping',
  executed        => 'execute',
  execution       => 'execute',
  importing       => 'import',
  'lexical scope' => 'lexical-scoping',
  qualifying      => 'qualified',
);

# Called from command line when pre-rendering docs, so cannot use the stash
sub _prepare_html ($c, $src, $url_perl_version, $pod_paths, $module, $function = undef, $variable = undef) {
  my $dom = Mojo::DOM->new($c->pod_to_html($src, $url_perl_version));

  my $url_prefix = $url_perl_version ? $c->append_url_path('/', $url_perl_version) : '';

  # Rewrite links to unknown documentation to MetaCPAN
  if ($module ne 'index' and $module ne 'search' and $module ne 'perltoc') {
    for my $e ($dom->find('a[href]')->each) {
      my $link = Mojo::URL->new($e->attr('href'));
      next if length $link->host;
      if ($link->path =~ m{^\Q$url_prefix\E/([^/]+)\z}) {
        my $module = $1;
        next if exists $pod_paths->{$module};
        my $metacpan_url = $c->append_url_path('https://metacpan.org/pod', $module);
        $metacpan_url->fragment($link->fragment) if length $link->fragment;
        $e->attr(href => $metacpan_url);
      }
    }
  }

  # Rewrite code blocks for syntax highlighting and correct indentation
  for my $e ($dom->find('pre > code')->each) {
    my $str = $e->all_text;
    my $add_class;
    if ($module eq 'perl' or $module eq 'index' or length $str > 5000) {
      $add_class = 'nohighlight';
    } elsif ($str !~ m/[\$\@\%]\w|->\w|[;{]\s*(?:#|$)/m) {
      $add_class = 'plaintext';
    }
    if (defined $add_class) {
      my $attrs = $e->attr;
      $attrs->{class} = join ' ', grep { defined } $attrs->{class}, $add_class;
    }
  }

  if ($module eq 'functions') {
    # Rewrite links on function pages
    for my $e ($dom->find('a[href]')->each) {
      my $link = Mojo::URL->new($e->attr('href'));
      next if length $link->path;
      next unless length(my $fragment = $link->fragment);
      my ($function_name) = $fragment =~ m/^(.[^-]*)/;
      $e->attr(href => $c->url_for($c->append_url_path("$url_prefix/functions/", $function_name)));
    }

    # Insert links on functions index
    if (!defined $function) {
      for my $e ($dom->find(':not(a) > code')->each) {
        my $text = $e->all_text;
        $e->wrap($c->link_to('' => $c->url_for($c->append_url_path("$url_prefix/functions/", "$1"))))
          if $text =~ m/^([-\w]+)\/*$/ or $text =~ m/^([-\w\/]+)$/;
      }
    }
  }

  # Rewrite links on variable pages
  if ($module eq 'variables') {
    for my $e ($dom->find('a[href]')->each) {
      my $link = Mojo::URL->new($e->attr('href'));
      next if length $link->path;
      next unless length (my $fragment = $link->fragment);
      if ($fragment =~ m/^[\$\@%]/ or $fragment =~ m/^[a-zA-Z]+$/) {
        $e->attr(href => $c->url_for($c->append_url_path("$url_prefix/variables/", $fragment)));
      } else {
        $e->attr(href => $c->url_for(Mojo::URL->new("$url_prefix/perlvar")->fragment($fragment)));
      }
    }

    # Insert links on variables index
    if (!defined $variable) {
      for my $e ($dom->find('li > p:first-of-type > b')->each) {
        my $text = $e->all_text;
        $e->wrap($c->link_to('' => $c->url_for($c->append_url_path("$url_prefix/variables/", $text))))
          if $text =~ m/^[\$\@%]/ or $text =~ m/^[a-zA-Z]+$/;
      }
    }
  }

  # Insert links on perldoc perl
  if ($module eq 'perl' or $module eq 'index') {
    for my $e ($dom->find('pre > code')->each) {
      my $str = $e->content;
      $e->content($str) if $str =~ s/^\s*\K(perl\S+)/$c->link_to("$1" => $c->url_for($c->append_url_path("$url_prefix\/", "$1")))/mge;
    }
    for my $e ($dom->find(':not(pre) > code')->each) {
      my $text = $e->all_text;
      $e->wrap($c->link_to('' => $c->url_for($c->append_url_path("$url_prefix/", "$1")))) if $text =~ m/^perldoc (\w+)$/;
      $e->content($text) if $text =~ s/^use \K([a-z]+)(;|$)/$c->link_to("$1" => $c->url_for($c->append_url_path("$url_prefix\/", "$1"))) . $2/e;
    }
    for my $e ($dom->find('p > b')->each) {
      my $text = $e->all_text;
      $e->content($text) if $text =~ s/^use \K([a-z]+)(;|$)/$c->link_to("$1" => $c->url_for($c->append_url_path("$url_prefix\/", "$1"))) . $2/e;
    }
  }

  # Insert links on perlglossary
  if ($module eq 'perlglossary') {
    my %words = %perlglossary_anchors;
    for my $e ($dom->find('dt')->each) {
      my $id = $e->{id} // next;
      my $text = lc $e->all_text;
      $words{$text} = $words{$text =~ tr/ /-/r} = $words{"${text}s"} = $words{"${text}es"} = $id;
      $words{$_} //= $id for split ' ', $text;
    }

    for my $e ($dom->find('dd b')->each) {
      my $text = lc $e->all_text;
      next unless $text =~ m/^[a-z]/;
      my $anchor = $words{$text};
      if (defined $anchor) {
        $e->wrap($c->link_to('' => "#$anchor"));
      } else {
        $c->app->log->debug("($url_perl_version) No perlglossary heading found for '$text'");
      }
    }
  }

  if ($module eq 'search') {
    # Rewrite links to function pages
    for my $e ($dom->find('a[href]')->each) {
      next unless $e->attr('href') =~ /^[^#]+perlfunc#(.[^-]*)/;
      my $function_name = url_unescape "$1";
      $e->attr(href => $c->url_for($c->append_url_path("$url_prefix/functions/", $function_name)))->content($function_name);
    }
  }

  # Insert permalinks
  my $linkable = 'h1, h2, h3, h4';
  $linkable .= ', dt' unless $module eq 'search';
  for my $e ($dom->find($linkable)->each) {
    my $link = Mojo::URL->new->fragment($e->{id});
    my $permalink = $c->link_to('#' => $link, class => 'permalink');
    $e->content($permalink . $e->content);
  }

  return $dom;
}

my %toc_level = (h1 => 1, h2 => 2, h3 => 3, h4 => 4);

sub _render_html ($c, $dom) {
  my $module = $c->stash('module');
  # Try to find a title
  my $title = $c->stash('page_name') // $module;
  $dom->find('h1')->first(sub {
    return unless $_->all_text =~ m/^\s*#?\s*NAME\s*$/i;
    my $p = $_->next;
    return unless $p->tag eq 'p';
    $title = trim($p->all_text);
  });

  # Assemble table of contents
  my @toc;
  unless ($module eq 'index') {
    my $parent;
    for my $e ($dom->find('h1, h2, h3, h4')->each) {
      my $link = Mojo::URL->new->fragment($e->{id});
      my $text = $e->all_text =~ s/^#//r;
      my $entry = {tag => $e->tag, text => $text, link => $link};
      $parent = $parent->{parent} until !defined $parent
        or $toc_level{$e->tag} > $toc_level{$parent->{tag}};
      if (defined $parent) {
        weaken($entry->{parent} = $parent);
        push @{$parent->{contents}}, $entry;
      } else {
        push @toc, $entry;
      }
      $parent = $entry;
    }
  }

  # Combine everything to a proper response
  $c->content_for(perldoc => "$dom");
  $c->render('perldoc', title => $title, toc => \@toc);
}

my %index_redirects = (
  'index-faq' => 'perlfaq',
  'index-functions' => 'functions#Alphabetical-Listing-of-Perl-Functions',
  'index-functions-by-cat' => 'functions#Perl-Functions-by-Category',
  'index-history' => 'perl#Miscellaneous',
  'index-internals' => 'perl#Internals-and-C-Language-Interface',
  'index-language' => 'perl#Reference-Manual',
  'index-licence' => 'perlartistic',
  'index-overview' => 'perl#Overview',
  'index-platforms' => 'perl#Platform-Specific',
  'index-pragmas' => 'modules#Pragmatic-Modules',
  'index-tutorials' => 'perl#Tutorials',
  'index-utilities' => 'perlutil',
);
$index_redirects{"index-modules-$_"} = 'modules#Standard-Modules' for 'A'..'Z';

sub _perldoc ($c) {
  my $module = $c->stash('module');
  my $url_perl_version = $c->stash('url_perl_version');
  my $perl_version = $c->stash('perl_version');

  # Legacy index page redirects
  if (exists $index_redirects{$module}) {
    my $current_prefix = $url_perl_version ? $c->append_url_path('/', $url_perl_version) : '';
    $c->res->code(301);
    return $c->redirect_to($c->url_for("$current_prefix/$index_redirects{$module}")->to_abs);
  }

  # Legacy separator redirects
  if ($module =~ m!/!) {
    $module =~ s!/+!::!g;
    my $current_prefix = $url_perl_version ? $c->append_url_path('/', $url_perl_version) : '';
    $c->res->code(301);
    return $c->redirect_to($c->url_with("$current_prefix/$module")->to_abs);
  }

  $c->stash(page_name => $module);

  $c->respond_to(
    txt => sub {
      my $path = _find_pod($c, $perl_version, $module) // return $c->reply->not_found;
      $c->render(data => path($path)->slurp);
    },
    html => sub {
      $c->stash(cpan => $c->append_url_path('https://metacpan.org/pod', $module));
      $c->stash(latest_url => $c->latest_has_doc($module) ? $c->url_with($c->current_doc_path) : undef);

      my $dom;
      if (defined(my $html_path = _find_html($c, $url_perl_version, $perl_version, $module))) {
        $dom = Mojo::DOM->new(decode 'UTF-8', path($html_path)->slurp);
      } elsif (defined(my $pod_path = _find_pod($c, $perl_version, $module))) {
        $dom = $c->prepare_perldoc_html(path($pod_path)->slurp, $url_perl_version, $c->pod_paths($perl_version), $module);
      } else {
        return $c->reply->not_found;
      }

      if (defined(my $module_meta = _find_module($c, $perl_version, $module))) {
        $c->stash(module_version => $module_meta->version($module));
      }

      if (defined $c->app->search_backend) {
        my $function = $c->function_name_match($c->stash('perl_version'), $module);
        $c->stash(alt_page_type => 'function', alt_page_name => $function) if defined $function;
      }

      $c->render_perldoc_html($dom);
    },
  );
}

sub _function ($c) {
  my $function = $c->stash('function');
  my $url_perl_version = $c->stash('url_perl_version');
  my $perl_version = $c->stash('perl_version');

  $c->stash(page_name => $function);

  $c->respond_to(
    txt => sub {
      my $src = _get_function_pod($c, $perl_version, $function) // return $c->reply->not_found;
      $c->render(data => $src);
    },
    html => sub {
      $c->stash(cpan => Mojo::URL->new('https://metacpan.org/pod/perlfunc')->fragment($function));
      $c->stash(latest_url => $c->url_with($c->current_doc_path));

      my $dom;
      if (defined(my $html_path = _find_html($c, $url_perl_version, $perl_version, 'functions', $function))) {
        $dom = Mojo::DOM->new(decode 'UTF-8', path($html_path)->slurp);
      } elsif (defined(my $src = _get_function_pod($c, $perl_version, $function))) {
        $dom = $c->prepare_perldoc_html($src, $url_perl_version, $c->pod_paths($perl_version), 'functions', $function);
      } else {
        return $c->reply->not_found;
      }

      my $heading = $dom->at('dt[id]');
      if (defined $heading) {
        $c->stash(cpan => Mojo::URL->new('https://metacpan.org/pod/perlfunc')->fragment($heading->{id}));
      }

      if (defined $c->app->search_backend) {
        my $pod = $c->pod_name_match($perl_version, $function);
        $c->stash(alt_page_type => 'module', alt_page_name => $pod) if defined $pod;
      }

      $c->render_perldoc_html($dom);
    },
  );
}

sub _get_function_pod ($c, $perl_version, $function) {
  my $path = _find_pod($c, $perl_version, 'perlfunc') // return undef;
  my $src = path($path)->slurp;
  return $c->function_pod_page($src, $function);
}

sub _variable ($c) {
  my $variable = $c->stash('variable');
  my $url_perl_version = $c->stash('url_perl_version');
  my $perl_version = $c->stash('perl_version');

  $c->stash(page_name => $variable);

  $c->respond_to(
    txt => sub {
      my $src = _get_variable_pod($c, $perl_version, $variable) // return $c->reply->not_found;
      $c->render(data => $src);
    },
    html => sub {
      $c->stash(cpan => Mojo::URL->new('https://metacpan.org/pod/perlvar')->fragment($variable));
      $c->stash(latest_url => $c->url_with($c->current_doc_path));

      my $dom;
      if (defined(my $html_path = _find_html($c, $url_perl_version, $perl_version, 'variables', $variable))) {
        $dom = Mojo::DOM->new(decode 'UTF-8', path($html_path)->slurp);
      } elsif (defined(my $src = _get_variable_pod($c, $perl_version, $variable))) {
        $dom = $c->prepare_perldoc_html($src, $url_perl_version, $c->pod_paths($perl_version), 'variables', undef, $variable);
      } else {
        return $c->reply->not_found;
      }

      my $heading = $dom->at('dt[id]');
      if (defined $heading) {
        $c->stash(cpan => Mojo::URL->new('https://metacpan.org/pod/perlvar')->fragment($heading->{id}));
      }

      $c->render_perldoc_html($dom);
    },
  );
}

sub _get_variable_pod ($c, $perl_version, $variable) {
  my $path = _find_pod($c, $perl_version, 'perlvar') // return undef;
  my $src = path($path)->slurp;
  return $c->variable_pod_page($src, $variable);
}

sub _index ($c) {
  my $url_perl_version = $c->stash('url_perl_version');
  my $perl_version = $c->stash('perl_version');
  my $page = $c->stash('module');
  
  my $url_prefix = $url_perl_version ? $c->append_url_path('/', $url_perl_version) : '';
  my $pod_source = $c->index_stash($page)->{pod_source};
  my $backup_url = $c->url_for("$url_prefix/$pod_source");

  $c->respond_to(
    txt => sub {
      my $src = _get_index_page($c, $perl_version, $page) // return $c->res->code(302) && $c->redirect_to($backup_url);
      $c->render(data => $src);
    },
    html => sub {
      $c->stash(latest_url => $c->url_with($c->current_doc_path));

      my $dom;
      if (defined(my $html_path = _find_html($c, $url_perl_version, $perl_version, $page))) {
        $dom = Mojo::DOM->new(decode 'UTF-8', path($html_path)->slurp);
      } elsif (defined(my $src = _get_index_page($c, $perl_version, $page))) {
        $dom = $c->prepare_perldoc_html($src, $url_perl_version, $c->pod_paths($perl_version), $page);
      } else {
        $c->res->code(302);
        return $c->redirect_to($backup_url);
      }

      $c->render_perldoc_html($dom);
    },
  );
}

sub _get_index_page ($c, $perl_version, $page) {
  my $pod = $c->index_stash($page)->{pod_source} // return undef;
  my $path = _find_pod($c, $perl_version, $pod) // return undef;
  my $src = path($path)->slurp;
  return $c->index_page($src, $perl_version, $page);
}

# The following functions are called from the command-line and cannot use the stash

sub _index_page ($c, $src, $perl_version, $page) {
  my $sub = __PACKAGE__->can("_index_page_$page") // return undef;
  return $sub->($c, $src, $perl_version);
}

sub _index_page_index ($c, $src, $perl_version) {
  my ($in_intro, $in_desc, @intro, @sections, @description);
  foreach my $para (split /\n\n+/, $src) {
    if ($para =~ m/^=head/) {
      $in_intro = $in_desc = 0;
    }
    if ($para =~ m/^=head1\s+(?:SYNOPSIS|GETTING HELP)/i) {
      $in_intro = 1;
      @intro = ();
    } elsif ($in_intro and $para !~ m/^B<perl>/) {
      push @intro, $para;
    } elsif ($para =~ m/^=head1\s+DESCRIPTION/i) {
      $in_desc = 1;
    } elsif ($in_desc) {
      push @description, $para;
    } elsif ($para =~ m/^=head2\s+(.*)/) {
      push @sections, $1;
    }
  }

  my @result;

  push @result, "=head1 Perl $perl_version Documentation", @intro;

  if (@sections) {
    push @result, '=over';
    foreach my $section (@sections) {
      my $name = $c->pod_to_text_content("=pod\n\n$section");
      push @result, '=item *', "L<< $name|perl/$section >>";
    }
    push @result, '=back';
  }

  push @result, 'I<Full perl(1) documentation: L<perl>>';

  push @result, '=head2 Reference Lists', '=over';
  push @result, '=item *', 'L<Operators|perlop>';
  push @result, '=item *', "L<< \u$_|$_ >>" for qw(functions variables modules);
  push @result, '=item *', 'L<Utilities|perlutil>';
  push @result, '=back';

  push @result, '=head2 More Info', '=over';
  push @result, '=item *', "L<Perl $perl_version Release Notes|perldelta>" unless $perl_version eq 'blead';
  push @result, '=item *', 'L<Community|perlcommunity>';
  push @result, '=item *', 'L<FAQs|perlfaq>';
  push @result, '=back';

  push @result, '=head2 About Perl', @description;

  return undef unless @result;
  return join "\n\n", @result;
}

sub _index_page_functions ($c, $src, $perl_version) {
  my $categories = _get_function_categories($c, $src);
  my $descriptions = _get_function_list($c, $perl_version);
  return undef unless defined $categories or defined $descriptions;
  return join "\n\n", '=pod', 'I<Full documentation of builtin functions: L<perlfunc>>',
    grep { defined } $categories, $descriptions;
}

sub _get_function_categories ($c, $src) {
  my ($started, @result);
  foreach my $para (split /\n\n+/, $src) {
    if (!$started and $para =~ m/^=head2 Perl Functions by Category/) {
      $started = 1;
      push @result, $para;
    } elsif ($started) {
      last if $para =~ m/^=head/;
      push @result, $para;
    }
  }

  return undef unless $started;
  return join "\n\n", @result;
}

sub _get_function_list ($c, $perl_version) {
  my $names = $c->function_names($perl_version);
  return undef unless @$names;
  my $descriptions = $c->function_descriptions($perl_version);
  my @result = ('=head2 Alphabetical Listing of Perl Functions', '=over');
  foreach my $name (@$names) {
    my $desc = $descriptions->{$name};
    my $escaped = _escape_pod($name);
    my $item = "C<$escaped>";
    $item .= " - $desc" if defined $desc;
    push @result, '=item *', $item;
  }
  push @result, '=back';
  return join "\n\n", @result;
}

sub _index_page_variables ($c, $src, $perl_version) {
  my ($level, @names, $heading, @section, @result) = (0);
  foreach my $para (split /\n\n+/, $src) {
    if ($level == 1 and $para =~ m/^=item\s+(.*)/) {
      push @names, $1;
    } elsif ($level == 1 and $para !~ m/^=/ and @names) {
      @names = $names[-1] unless $names[0] eq '$a' or $names[0] eq '$b';
      my $name = join ', ', map { "B<< $_ >>" } @names;
      # extract first sentence as description
      next if $para =~ m/^(?:See\b|WARNING:|This variable is no longer supported)/;
      $para =~ s/.*?(?=Perl)//is if $names[-1] eq '$^M';
      my $sentences = get_sentences $para;
      my $desc = shift @$sentences;
      $desc =~ s/\.$//;
      push @section, '=item *', "$name - $desc";
      @names = ();
    } elsif ($para =~ m/^=over/) {
      push @section, $para unless $level;
      $level++;
    } elsif ($para =~ m/^=back/) {
      $level--;
      push @section, $para unless $level;
    } elsif ($para =~ m/^=head[23]/ and $para !~ m/^=head\d Performance issues/) {
      push @result, $heading, @section if @section;
      @section = ();
      $heading = $para;
    }
  }
  push @result, $heading, @section if @section;

  return undef unless @result;
  return join "\n\n", '=pod', 'I<Full documentation of predefined variables: L<perlvar>>', @result;
}

sub _index_page_modules ($c, $src, $perl_version) {
  my ($started, $standard, $name, @result);
  foreach my $para (split /\n\n+/, $src) {
    if (!$started and $para =~ m/^=head\d Pragmatic Modules/) {
      $started = 1;
      push @result, $para;
    } elsif ($started) {
      $standard = 1 if $para =~ m/^=head\d Standard Modules/;
      if ($para =~ m/^=item\s+(.*)/) {
        $name = $1;
        push @result, '=item *';
      } elsif ($para !~ m/^=/ and defined $name) {
        push @result, "B<<< L<< $name >> >>> - $para";
        undef $name;
      } else {
        push @result, $para;
      }
      last if $standard and $para =~ m/^=back/;
    }
  }

  return undef unless @result;
  return join "\n\n", @result;
}

sub _function_pod_page ($c, $src, $function) {
  my $result = $c->split_functions($src, $function);
  return undef unless @$result;
  return join "\n\n", '=over', @$result, '=back';
}

sub _variable_pod_page ($c, $src, $variable) {
  my $result = $c->split_variables($src, $variable);
  return undef unless @$result;
  return join "\n\n", '=over', @$result, '=back';
}

# Edge cases: eval, do, select, chop, q/STRING/, y///, -X, getgrent, __END__
sub _split_functions ($src, $function = undef) {
  my $list_level = 0;
  my $found = '';
  my ($started, $found_filetest, %found_function, @functions);
  my $function_is_filetest = !!(defined $function and $function =~ m/^-[a-zA-WYZ]$/);

  foreach my $para (split /\n\n+/, $src) {
    $started = 1 if !$started and $para =~ m/^=head\d Alphabetical Listing of Perl Functions/;
    next unless $started;
    next if $para =~ m/^=for Pod::Functions/;

    # keep track of list depth
    if ($para =~ m/^=over/) {
      $list_level++;
      # skip the list start directive
      next if $list_level == 1;
    }
    if ($para =~ m/^=back/) {
      $list_level--;
      # complete processing of a function if leaving the list
      if ($found and $list_level == 0) {
        if (defined $function and $found eq 'content') {
          # we're done, unless we were checking the -X section for filetest operators and didn't find it
          return $found_function{contents} // [] unless $function_is_filetest and $found_function{is_filetest} and !$found_filetest;
        } elsif (!defined $function) {
          if (defined(my $first_name = $found_function{first_name})) {
            # add this function section
            delete $found_function{names}{$first_name};
            push @functions, {contents => $found_function{contents}, names => [$first_name, sort keys %{$found_function{names}}]};
          }
        }
        %found_function = ();
        $found = '';
      }
    }

    # functions are only declared at depth 1
    if ($list_level == 1) {
      if ($para =~ m/^=item/) {
        # new function heading
        unless (defined $function) {
          # this indicates a new function section if we found content
          if ($found eq 'content') {
            if (defined(my $first_name = $found_function{first_name})) {
              # add this function section
              delete $found_function{names}{$first_name};
              push @functions, {contents => $found_function{contents}, names => [$first_name, sort keys %{$found_function{names}}]};
            }
            %found_function = ();
          }
          $found = 'header';
        }

        my $heading = _pod_to_text_content("=over\n\n$para\n\n=back");
        if (defined $function) {
          # see if this is the start or end of the function we want
          my $is_function_header = !!($heading =~ m/^\Q$function\E(\W|$)/ or ($function_is_filetest and $heading =~ m/^-X\b/));
          $found = 'header' if !$found and $is_function_header;
          # keep processing until we have found content and then a non-matching heading
          if ($found eq 'content' and !$is_function_header) {
            # we're done, unless we were checking the -X section for filetest operators and didn't find it
            return $found_function{contents} // [] unless $function_is_filetest and $found_function{is_filetest} and !$found_filetest;
            %found_function = ();
            $found = '';
          }
        }

        # track names to navigate to this function
        if ($heading =~ m/^([-\w\/]+)/) {
          $found_function{names}{"$1"} //= 1;
          $found_function{first_name} //= "$1";
        }
        # name variants without trailing slashes
        $found_function{names}{"$1"} //= 1 if $heading =~ m/^([-\w]+)/;
        # check -X section later for filetest operators
        $found_function{is_filetest} = 1 if $heading =~ m/^-X\b/;
      } elsif ($found eq 'header') {
        # function content if we're in a function section
        $found = 'content';
      } elsif (!$found and defined $function) {
        # skip content if this isn't the function section we're looking for
        %found_function = ();
        next;
      }
    }

    # process function contents at depth 1+
    if ($list_level >= 1) {
      # check -X section content for filetest operators
      if ($found_function{is_filetest}) {
        $found_function{names}{"$_"} //= 1 for $para =~ m/^\s+(-[a-zA-Z])\s/mg;
        $found_filetest = 1 if $function_is_filetest and $found_function{names}{$function};
      }
      # add content to function section
      push @{$found_function{contents}}, $para;
    }
  }

  return defined $function ? $found_function{contents} // [] : \@functions;
}

sub _split_variables ($src, $variable = undef) {
  my $list_level = 0;
  my $found = '';
  my ($started, %found_variable, @variables);

  foreach my $para (split /\n\n+/, $src) {
    # keep track of list depth
    if ($para =~ m/^=over/) {
      $list_level++;
      # skip the list start directive
      next if $list_level == 1;
    }
    if ($para =~ m/^=back/) {
      $list_level--;
      # complete processing of a variable if leaving the list
      if ($found and $list_level == 0) {
        return $found_variable{contents} // [] if defined $variable;
        push @variables, {contents => $found_variable{contents}, names => [sort keys %{$found_variable{names}}]};
        %found_variable = ();
        $found = '';
      }
    }

    # variables are only declared at depth 1
    if ($list_level == 1) {
      if ($para =~ m/^=item/) {
        unless (defined $variable) {
          # this indicates a new variable section if we found content
          if ($found eq 'content') {
            push @variables, {contents => $found_variable{contents}, names => [sort keys %{$found_variable{names}}]};
            %found_variable = ();
          }
          $found = 'header';
        }

        my $heading = _pod_to_text_content("=over\n\n$para\n\n=back");
        if (defined $variable) {
          # see if this is the start or end of the variable we want
          my $is_variable_header = !!($heading eq $variable);
          $found = 'header' if !$found and $is_variable_header;
          return $found_variable{contents} // [] if $found eq 'content' and !$is_variable_header;
        }

        # track names to navigate to this variable
        $found_variable{names}{"$1"} //= 1 if $heading =~ m/^([\$\@%].+)$/ or $heading =~ m/^([a-zA-Z]+)$/;
      } elsif ($found eq 'header') {
        # variable content if we're in a variable section
        $found = 'content';
      } elsif (!$found and defined $variable) {
        # skip content if this isn't the variable section we're looking for
        %found_variable = ();
        next;
      }
    }

    # variable contents at depth 1+
    push @{$found_variable{contents}}, $para if $list_level >= 1;
  }

  return defined $variable ? $found_variable{contents} // [] : \@variables;
}

# edge case: perlfaq4
sub _split_faqs ($src) {
  my $found = '';
  my (%found_faq, @faqs);

  foreach my $para (split /\n\n+/, $src) {
    if ($found and $para =~ m/^=head1/) {
      push @faqs, {contents => $found_faq{contents}, questions => [sort keys %{$found_faq{questions}}]};
      %found_faq = ();
      $found = '';
    }

    if ($para =~ m/^=head2/) {
      # this indicates a new faq section if we found content
      if ($found eq 'content') {
        push @faqs, {contents => $found_faq{contents}, questions => [sort keys %{$found_faq{questions}}]};
        %found_faq = ();
      }
      $found = 'header';

      my $heading = _pod_to_text_content("=pod\n\n$para");

      # track questions to search this faq section
      $found_faq{questions}{$heading} //= 1;
    } elsif ($found eq 'header') {
      # faq answer if we're in a faq section
      $found = 'content';
    }

    # faq section
    push @{$found_faq{contents}}, $para if $found;
  }

  return \@faqs;
}

sub _split_perldelta ($src) {
  my $found = '';
  my ($started, %found_section, @sections);

  foreach my $para (split /\n\n+/, $src) {
    $started = 1 if !$started and $para =~ m/^=head\d/ and $para !~ m/^=head1\s+(NAME|DESCRIPTION)$/;
    next unless $started;

    if ($para =~ m/^=head\d/) {
      # this indicates a new section if we found content
      if ($found eq 'content') {
        push @sections, {contents => $found_section{contents}, heading => $found_section{heading}};
        %found_section = ();
      } elsif ($found eq 'header') {
        # Don't include previous headings in contents
        %found_section = ();
      }
      $found = 'header';

      my $heading = _pod_to_text_content("=pod\n\n$para");

      # track innermost heading to search this perldelta section
      $found_section{heading} = $heading;
    } elsif ($found eq 'header') {
      # section content if we're in a section
      $found = 'content';
    }

    last if $para =~ m/^=head1\s+Reporting Bugs$/;

    # section content
    push @{$found_section{contents}}, $para;
  }

  return \@sections;
}

sub _cache_perl_to_html ($c, $perl_version, $types = undef) {
  my $url_version = my $real_version = my $path_version = $perl_version;
  if ($perl_version eq 'latest') {
    $url_version = '';
    $real_version = $c->app->latest_perl_version;
    $path_version = "latest-$real_version";
  }

  my $pod_paths = $c->app->pod_paths($real_version) // {};
  return unless keys %$pod_paths;

  my $version_dir = $c->app->home->child('html', $path_version)->remove_tree({keep_root => 1})->make_path;

  if (!defined $types or $types->{pods}) {
    foreach my $pod (keys %$pod_paths) {
      my $filename = sha1_sum(encode 'UTF-8', $pod) . '.html';
      print "Rendering $pod for $perl_version to $filename\n";
      my $dom = $c->app->prepare_perldoc_html(path($pod_paths->{$pod})->slurp, $url_version, $pod_paths, $pod);
      $version_dir->child($filename)->spew(encode 'UTF-8', $dom->to_string);
    }
  }

  if (!defined $types or $types->{indexes}) {
    foreach my $index (@{$c->app->index_pages}) {
      my $pod_source = $c->app->index_stash($index)->{pod_source} // next;
      next unless defined $pod_paths->{$pod_source};
      my $filename = sha1_sum(encode 'UTF-8', $index) . '.html';
      print "Rendering index page $index for $perl_version to $filename\n";
      my $src = $c->app->index_page(path($pod_paths->{$pod_source})->slurp, $real_version, $index);
      my $dom = $c->app->prepare_perldoc_html($src, $url_version, $pod_paths, $index);
      $version_dir->child($filename)->spew(encode 'UTF-8', $dom->to_string);
    }
  }

  if (!defined $types or $types->{functions}) {
    if (defined $pod_paths->{perlfunc}) {
      my $functions_dir = $version_dir->child('functions')->make_path;

      my $perlfunc_pod = path($pod_paths->{perlfunc})->slurp;
      my %functions = map { ($_ => 1) } map { @{$_->{names}} } @{$c->split_functions($perlfunc_pod)};

      foreach my $function (keys %functions) {
        my $filename = sha1_sum(encode 'UTF-8', $function) . '.html';
        print "Rendering function $function for $perl_version to $filename\n";
        my $function_pod = $c->function_pod_page($perlfunc_pod, $function);
        my $dom = $c->app->prepare_perldoc_html($function_pod, $url_version, $pod_paths, 'functions', $function);
        $functions_dir->child($filename)->spew(encode 'UTF-8', $dom->to_string);
      }
    }
  }

  if (!defined $types or $types->{variables}) {
    if (defined $pod_paths->{perlvar}) {
      my $variables_dir = $version_dir->child('variables')->make_path;

      my $perlvar_pod = path($pod_paths->{perlvar})->slurp;
      my %variables = map { ($_ => 1) } map { @{$_->{names}} } @{$c->split_variables($perlvar_pod)};

      foreach my $variable (keys %variables) {
        my $filename = sha1_sum(encode 'UTF-8', $variable) . '.html';
        print "Rendering variable $variable for $perl_version to $filename\n";
        my $variable_pod = $c->variable_pod_page($perlvar_pod, $variable);
        my $dom = $c->app->prepare_perldoc_html($variable_pod, $url_version, $pod_paths, 'variables', undef, $variable);
        $variables_dir->child($filename)->spew(encode 'UTF-8', $dom->to_string);
      }
    }
  }
}

sub _pod_to_html ($pod, $url_perl_version = '', $with_errata = 1) {
  my $parser = MetaCPAN::Pod::HTML->new;
  $parser->perldoc_url_prefix($url_perl_version ? "/$url_perl_version/" : '/');
  $parser->$_('') for qw(html_header html_footer);
  $parser->anchor_items(1);
  $parser->no_errata_section(1) unless $with_errata;
  $parser->expand_verbatim_tabs(0);
  $parser->output_string(\(my $output));
  $parser->parse_string_document("$pod");
  return $output;
}

sub _pod_to_text_content ($pod) {
  my $parser = Pod::Simple::TextContent->new;
  $parser->no_errata_section(1);
  $parser->output_string(\(my $output));
  $parser->parse_string_document("$pod");
  return trim($output);
}

my %escapes = ('<' => 'lt', '>' => 'gt', '|' => 'verbar', '/' => 'sol', '"' => 'quot');
sub _escape_pod ($text) {
  return $text =~ s/([<>|\/])/E<$escapes{$1}>/gr;
}

sub _append_url_path ($url, $segment) {
  $url = Mojo::URL->new($url) unless ref $url;
  push @{$url->path->parts}, $segment;
  $url->path->trailing_slash(0);
  return $url;
}

1;
