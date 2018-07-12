package PerldocBrowser::Plugin::PerldocRenderer;

# This software is Copyright (c) 2008-2018 Sebastian Riedel and others, 2018 Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
use Mojo::Base 'Mojolicious::Plugin';
use List::Util 'first';
use MetaCPAN::Pod::XHTML;
use Module::Metadata;
use Mojo::ByteStream;
use Mojo::DOM;
use Mojo::File 'path';
use Mojo::URL;
use Mojo::Util qw(trim url_unescape);
use Pod::Simple::Search;
use experimental 'signatures';

sub register ($self, $app, $conf) {
  $app->helper(split_functions => sub ($c, @args) { _split_functions(@args) });
  $app->helper(split_variables => sub ($c, @args) { _split_variables(@args) });
  $app->helper(split_faqs => sub ($c, @args) { _split_faqs(@args) });
  $app->helper(pod_to_html => sub ($c, @args) { _pod_to_html(@args) });
  $app->helper(escape_pod => sub ($c, @args) { _escape_pod(@args) });
  $app->helper(render_perldoc_html => \&_html);

  my %defaults = (
    module => 'perl',
    perl_version => $app->latest_perl_version,
    url_perl_version => '',
  );

  foreach my $perl_version (@{$app->all_perl_versions}) {
    $app->routes->any("/$perl_version/functions/:function"
      => {%defaults, perl_version => $perl_version, url_perl_version => $perl_version, module => 'functions'}
      => [function => qr/[^.]+/] => \&_function);
    $app->routes->any("/$perl_version/variables/:variable"
      => {%defaults, perl_version => $perl_version, url_perl_version => $perl_version, module => 'perlvar'}
      => [variable => qr/[^.]+(?:\.{3}[^.]+|\.)?/] => \&_variable);
    $app->routes->any("/$perl_version/functions"
      => {%defaults, perl_version => $perl_version, url_perl_version => $perl_version, module => 'functions'}
      => \&_functions_index);
    $app->routes->any("/$perl_version/modules"
      => {%defaults, perl_version => $perl_version, url_perl_version => $perl_version, module => 'modules'}
      => \&_modules_index);
    $app->routes->any("/$perl_version/:module"
      => {%defaults, perl_version => $perl_version, url_perl_version => $perl_version}
      => [module => qr/[^.]+(?:\.[0-9]+)*/] => \&_perldoc);
  }

  $app->routes->any("/functions/:function" => {%defaults, module => 'functions'} => [function => qr/[^.]+/] => \&_function);
  $app->routes->any("/variables/:variable" => {%defaults, module => 'perlvar'} => [variable => qr/[^.]+(?:\.{3}[^.]+|\.)?/] => \&_variable);
  $app->routes->any("/functions" => {%defaults, module => 'functions'} => \&_functions_index);
  $app->routes->any("/modules" => {%defaults, module => 'modules'} => \&_modules_index);
  $app->routes->any("/:module" => {%defaults} => [module => qr/[^.]+(?:\.[0-9]+)*/] => \&_perldoc);
}

sub _find_pod($c, $module) {
  my $inc_dirs = $c->inc_dirs($c->stash('perl_version'));
  return Pod::Simple::Search->new->inc(0)->find($module, @$inc_dirs);
}

sub _find_module($c, $module) {
  my $inc_dirs = $c->inc_dirs($c->stash('perl_version'));
  return Module::Metadata->new_from_module($module, inc => $inc_dirs);
}

sub _html ($c, $src) {
  my $dom = Mojo::DOM->new($c->pod_to_html($src, $c->stash('url_perl_version')));

  # Rewrite code blocks for syntax highlighting and correct indentation
  for my $e ($dom->find('pre > code')->each) {
    next if (my $str = $e->content) =~ /^\s*(?:\$|Usage:)\s+/m;
    next unless $str =~ /[\$\@\%]\w|-&gt;\w|^use\s+\w/m;
    my $attrs = $e->attr;
    my $class = $attrs->{class};
    $attrs->{class} = defined $class ? "$class prettyprint" : 'prettyprint';
  }

  my $url_perl_version = $c->stash('url_perl_version');
  my $url_prefix = $url_perl_version ? "/$url_perl_version" : '';

  if ($c->param('module') eq 'functions') {
    # Rewrite links on function pages
    for my $e ($dom->find('a[href]')->each) {
      my $link = Mojo::URL->new($e->attr('href'));
      next if length $link->path;
      next unless length(my $fragment = $link->fragment);
      my ($function) = $fragment =~ m/^(.[^-]*)/;
      $e->attr(href => Mojo::URL->new("$url_prefix/functions/")->path($function));
    }

    # Insert links on functions index
    if (!defined $c->param('function')) {
      for my $e ($dom->find(':not(a) > code')->each) {
        my $text = $e->all_text;
        $e->wrap($c->link_to('' => Mojo::URL->new("$url_prefix/functions/$1")))
          if $text =~ m/^([-\w]+)\/*$/ or $text =~ m/^([-\w\/]+)$/;
      }
    }
  }

  # Rewrite links on variable pages
  if (defined $c->param('variable')) {
    for my $e ($dom->find('a[href]')->each) {
      my $link = Mojo::URL->new($e->attr('href'));
      next if length $link->path;
      next unless length (my $fragment = $link->fragment);
      if ($fragment =~ m/^[\$\@%]/ or $fragment =~ m/^[a-zA-Z]+$/) {
        $e->attr(href => Mojo::URL->new("$url_prefix/variables/")->path($fragment));
      } else {
        $e->attr(href => Mojo::URL->new("$url_prefix/perlvar")->fragment($fragment));
      }
    }
  }

  # Insert links on modules list
  if ($c->param('module') eq 'modules') {
    for my $e ($dom->find('dt')->each) {
      my $module = $e->all_text;
      $e->child_nodes->last->wrap($c->link_to('' => Mojo::URL->new("$url_prefix/$module")));
    }
  }

  # Insert links on perldoc perl
  if ($c->param('module') eq 'perl') {
    for my $e ($dom->find('pre > code')->each) {
      my $str = $e->content;
      $e->content($str) if $str =~ s/^\s*\K(perl\S+)/$c->link_to("$1" => Mojo::URL->new("$url_prefix\/$1"))/mge;
    }
    for my $e ($dom->find(':not(pre) > code')->each) {
      my $text = $e->all_text;
      $e->wrap($c->link_to('' => Mojo::URL->new("$url_prefix/$1"))) if $text =~ m/^perldoc (\w+)$/;
      $e->content($text) if $text =~ s/^use \K([a-z]+)(;|$)/$c->link_to("$1" => Mojo::URL->new("$url_prefix\/$1")) . $2/e;
    }
    for my $e ($dom->find('p > b')->each) {
      my $text = $e->all_text;
      $e->content($text) if $text =~ s/^use \K([a-z]+)(;|$)/$c->link_to("$1" => Mojo::URL->new("$url_prefix\/$1")) . $2/e;
    }
  }

  if ($c->param('module') eq 'search') {
    # Rewrite links to function pages
    for my $e ($dom->find('a[href]')->each) {
      next unless $e->attr('href') =~ /^[^#]+perlfunc#(.[^-]*)/;
      my $function = url_unescape "$1";
      $e->attr(href => Mojo::URL->new("$url_prefix/functions/$function"))->content($function);
    }
  }

  # Rewrite headers
  my $highest = first { $dom->find($_)->size } qw(h1 h2 h3 h4);
  my @parts;
  my $linkable = 'h1, h2, h3, h4';
  $linkable .= ', dt' unless $c->param('module') eq 'search';
  for my $e ($dom->find($linkable)->each) {
    push @parts, [] if $e->tag eq ($highest // 'h1') || !@parts;
    my $link = Mojo::URL->new->fragment($e->{id});
    my $text = $e->all_text;
    push @{$parts[-1]}, $text, $link unless $e->tag eq 'dt';
    my $permalink = $c->link_to('#' => $link, class => 'permalink');
    $e->content($permalink . $e->content);
  }

  # Try to find a title
  my $title = $c->param('variable') // $c->param('function') // $c->param('module');
  $dom->find('h1 + p')->first(sub { $title = shift->text });

  # Combine everything to a proper response
  $c->content_for(perldoc => "$dom");
  $c->render('perldoc', title => $title, parts => \@parts);
}

sub _perldoc ($c) {
  # Find module or redirect to CPAN
  my $module = $c->param('module');
  $c->stash(cpan => "https://metacpan.org/pod/$module");

  my $path = _find_pod($c, $module);
  return $c->redirect_to($c->stash('cpan')) unless $path && -r $path;

  if (defined(my $module_meta = _find_module($c, $module))) {
    $c->stash(module_version => $module_meta->version($module));
  }

  my $src = path($path)->slurp;
  $c->respond_to(txt => {data => $src}, html => sub { $c->render_perldoc_html($src) });
}

sub _function ($c) {
  my $function = $c->param('function');
  $c->stash(cpan => "https://metacpan.org/pod/perlfunc#$function");

  my $src = _get_function_pod($c, $function);
  return $c->redirect_to($c->stash('cpan')) unless defined $src;

  $c->respond_to(txt => {data => $src}, html => sub { $c->render_perldoc_html($src) });
}

sub _variable ($c) {
  my $variable = $c->param('variable');
  my $escaped = $c->escape_pod($variable);
  my $link = Mojo::DOM->new($c->pod_to_html(qq{=pod\n\nL<< /"$escaped" >>}))->at('a');
  my $fragment = defined $link ? Mojo::URL->new($link->attr('href'))->fragment : $variable;
  $c->stash(cpan => Mojo::URL->new("https://metacpan.org/pod/perlvar")->fragment($fragment));

  my $src = _get_variable_pod($c, $variable);
  return $c->redirect_to($c->stash('cpan')) unless defined $src;

  $c->respond_to(txt => {data => $src}, html => sub { $c->render_perldoc_html($src) });
}

sub _functions_index ($c) {
  $c->stash(cpan => 'https://metacpan.org/pod/perlfunc#Perl-Functions-by-Category');

  my $src = _get_function_categories($c);
  return $c->redirect_to($c->stash('cpan')) unless defined $src;

  $c->respond_to(txt => {data => $src}, html => sub { $c->render_perldoc_html($src) });
}

sub _modules_index ($c) {
  $c->stash(cpan => 'https://metacpan.org');

  my $src = _get_module_list($c);
  return $c->redirect_to($c->stash('cpan')) unless defined $src;

  $c->respond_to(txt => {data => $src}, html => sub { $c->render_perldoc_html($src) });
}

sub _get_function_pod ($c, $function) {
  my $path = _find_pod($c, 'perlfunc');
  return undef unless $path && -r $path;
  my $src = path($path)->slurp;

  my $result = $c->split_functions($src, $function);
  return undef unless @$result;
  return join "\n\n", '=over', @$result, '=back';
}

sub _get_variable_pod ($c, $variable) {
  my $path = _find_pod($c, 'perlvar');
  return undef unless $path && -r $path;
  my $src = path($path)->slurp;

  my $result = $c->split_variables($src, $variable);
  return undef unless @$result;
  return join "\n\n", '=over', @$result, '=back';
}

sub _get_function_categories ($c) {
  my $path = _find_pod($c, 'perlfunc');
  return undef unless $path && -r $path;
  my $src = path($path)->slurp;

  my ($started, @result);
  foreach my $para (split /\n\n+/, $src) {
    if (!$started and $para =~ m/^=head\d Perl Functions by Category/) {
      $started = 1;
      push @result, '=pod';
    } elsif ($started) {
      last if $para =~ m/^=head/;
      push @result, $para;
    }
  }

  return undef unless @result;
  return join "\n\n", @result;
}

sub _get_module_list ($c) {
  my $path = _find_pod($c, 'perlmodlib');
  return undef unless $path && -r $path;
  my $src = path($path)->slurp;

  my ($started, $standard, @result);
  foreach my $para (split /\n\n+/, $src) {
    if (!$started and $para =~ m/^=head\d Pragmatic Modules/) {
      $started = 1;
      push @result, $para;
    } elsif ($started) {
      $standard = 1 if $para =~ m/^=head\d Standard Modules/;
      push @result, $para;
      last if $standard and $para =~ m/^=back/;
    }
  }

  return undef unless @result;
  return join "\n\n", @result;
}

# Edge cases: eval, do, chop, y///, -X, getgrent, __END__
sub _split_functions ($src, $function = undef) {
  my $list_level = 0;
  my $found = '';
  my ($started, $filetest_section, $found_filetest, @function, @functions);

  foreach my $para (split /\n\n+/, $src) {
    $started = 1 if !$started and $para =~ m/^=head\d Alphabetical Listing of Perl Functions/;
    next unless $started;
    next if $para =~ m/^=for Pod::Functions/;

    # keep track of list depth
    if ($para =~ m/^=over/) {
      $list_level++;
      next if $list_level == 1;
    }
    if ($para =~ m/^=back/) {
      $list_level--;
      $found = 'end' if $found and $list_level == 0;
    }

    # functions are only declared at depth 1
    my ($is_header, $is_function_header);
    if ($list_level == 1) {
      $is_header = 1 if $para =~ m/^=item/;
      if ($is_header) {
        # new function heading
        if (defined $function) {
          my $heading = trim(Mojo::DOM->new(_pod_to_html("=over\n\n$para\n\n=back", undef, 0))->all_text);
          # check -X section later for filetest operators
          $filetest_section = 1 if !$found and $heading =~ m/^-X\b/ and $function =~ m/^-[a-zA-WYZ]$/;
          # see if this is the start or end of the function we want
          $is_function_header = 1 if $heading =~ m/^\Q$function\E(\W|$)/;
          $found = 'header' if !$found and $is_function_header;
          $found = 'end' if $found eq 'content' and !$is_function_header;
        } else {
          # this indicates a new function section if we found content
          $found = 'header' if !$found;
          $found = 'end' if $found eq 'content';
        }
      } elsif ($found eq 'header' or $filetest_section) {
        # function content if we're in a function section
        $found = 'content' unless $found eq 'end';
      } elsif (!$found and defined $function) {
        # skip content if this isn't the function section we're looking for
        @function = ();
        next;
      }
    }

    if ($found eq 'end') {
      if (defined $function) {
        # we're done, unless we were checking the -X section for filetest operators and didn't find it
        last unless $filetest_section and !$found_filetest;
      } else {
        # add this function section
        push @functions, [@function];
      }
      # start next function section
      @function = ();
      $filetest_section = 0;
      $found = $is_header && (!defined $function or $is_function_header) ? 'header' : '';
    }

    # function contents at depth 1+
    if ($list_level >= 1) {
      # check -X section content for filetest operators
      $found_filetest = 1 if $filetest_section and $para =~ m/^\s+\Q$function\E\s/m;
      # add content to function section
      push @function, $para;
    }
  }

  return defined $function ? \@function : \@functions;
}

sub _split_variables ($src, $variable = undef) {
  my $list_level = 0;
  my $found = '';
  my ($started, @variable, @variables);

  foreach my $para (split /\n\n+/, $src) {
    # keep track of list depth
    if ($para =~ m/^=over/) {
      $list_level++;
      next if $list_level == 1;
    }
    if ($para =~ m/^=back/) {
      $list_level--;
      $found = 'end' if $found and $list_level == 0;
    }

    # variables are only declared at depth 1
    my ($is_header, $is_variable_header);
    if ($list_level == 1) {
      $is_header = 1 if $para =~ m/^=item/;
      if ($is_header) {
        if (defined $variable) {
          my $heading = trim(Mojo::DOM->new(_pod_to_html("=over\n\n$para\n\n=back", undef, 0))->all_text);
          # see if this is the start or end of the variable we want
          $is_variable_header = 1 if $heading eq $variable;
          $found = 'header' if !$found and $is_variable_header;
          $found = 'end' if $found eq 'content' and !$is_variable_header;
        } else {
          # this indicates a new variable section if we found content
          $found = 'header' if !$found;
          $found = 'end' if $found eq 'content';
        }
      } elsif ($found eq 'header') {
        # variable content if we're in a variable section
        $found = 'content' unless $found eq 'end';
      } elsif (!$found and defined $variable) {
        # skip content if this isn't the variable section we're looking for
        @variable = ();
        next;
      }
    }

    if ($found eq 'end') {
      if (defined $variable) {
        # we're done
        last;
      } else {
        # add this variable section
        push @variables, [@variable];
      }
      # start next variable section
      @variable = ();
      $found = $is_header && (!defined $variable or $is_variable_header) ? 'header' : '';
    }

    # variable contents at depth 1+
    push @variable, $para if $list_level >= 1;
  }

  return defined $variable ? \@variable : \@variables;
}

sub _split_faqs ($src, $question = undef) {
  my $found = '';
  my ($started, @faq, @faqs);

  foreach my $para (split /\n\n+/, $src) {
    $found = 'end' if $found and $para =~ m/^=head1/;

    my ($is_header, $is_question_header);
    $is_header = 1 if $para =~ m/^=head2/;
    if ($is_header) {
      if (defined $question) {
        my $heading = trim(Mojo::DOM->new(_pod_to_html("=pod\n\n$para", undef, 0))->all_text);
        # see if this is the start or end of the question we want
        $is_question_header = 1 if $heading eq $question;
        $found = 'header' if !$found and $is_question_header;
        $found = 'end' if $found eq 'content' and !$is_question_header;
      } else {
        # this indicates a new faq section if we found content
        $found = 'header' if !$found;
        $found = 'end' if $found eq 'content';
      }
    } elsif ($found eq 'header') {
      # faq answer if we're in a faq section
      $found = 'content' unless $found eq 'end';
    } elsif (!$found and defined $question) {
      # skip content if this isn't the faq section we're looking for
      @faq = ();
      next;
    }

    if ($found eq 'end') {
      if (defined $question) {
        # we're done
        last;
      } else {
        # add this faq section
        push @faqs, [@faq];
      }
      # start next faq section
      @faq = ();
      $found = $is_header && (!defined $question or $is_question_header) ? 'header' : '';
    }

    # faq section
    push @faq, $para;
  }

  return defined $question ? \@faq : \@faqs;
}

sub _pod_to_html ($pod, $url_perl_version = '', $with_errata = 1) {
  my $parser = MetaCPAN::Pod::XHTML->new;
  $parser->perldoc_url_prefix($url_perl_version ? "/$url_perl_version/" : '/');
  $parser->$_('') for qw(html_header html_footer);
  $parser->anchor_items(1);
  $parser->no_errata_section(1) unless $with_errata;
  $parser->output_string(\(my $output));
  return $@ unless eval { $parser->parse_string_document("$pod"); 1 };

  return $output;
}

my %escapes = ('<' => 'lt', '>' => 'gt', '|' => 'verbar', '/' => 'sol', '"' => 'quot');
sub _escape_pod ($text) {
  return $text =~ s/([<>|\/])/E<$escapes{$1}>/gr;
}

1;
