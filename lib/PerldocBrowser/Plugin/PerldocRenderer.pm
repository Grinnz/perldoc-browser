package PerldocBrowser::Plugin::PerldocRenderer;

# This software is Copyright (c) 2008-2018 Sebastian Riedel and others, 2018 Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
use Mojo::Base 'Mojolicious::Plugin';
use List::Util 'first';
use MetaCPAN::Pod::XHTML;
use Mojo::ByteStream;
use Mojo::DOM;
use Mojo::File 'path';
use Mojo::URL;
use Mojo::Util 'url_unescape';
use Pod::Simple::Search;
use experimental 'signatures';

sub register ($self, $app, $conf) {
  $app->helper(pod_to_html => sub { my $c = shift; _pod_to_html(@_) });
  $app->helper(split_functions => sub { my $c = shift; _split_functions(@_) });

  my $perl_versions = $app->perl_versions;
  my $dev_versions = $app->dev_versions;

  my %defaults = (
    perl_versions => $perl_versions,
    dev_perl_versions => $dev_versions,
    module => 'perl',
    perl_version => $app->latest_perl_version,
    url_perl_version => '',
  );

  foreach my $perl_version (@$perl_versions, @$dev_versions) {
    $app->routes->any("/$perl_version/functions/:function"
      => {%defaults, perl_version => $perl_version, url_perl_version => $perl_version, module => 'functions'}
      => [function => qr/[^.]+/] => \&_function);
    $app->routes->any("/$perl_version/functions"
      => {%defaults, perl_version => $perl_version, url_perl_version => $perl_version, module => 'functions'}
      => \&_functions_index);
    $app->routes->any("/$perl_version/modules"
      => {%defaults, perl_version => $perl_version, url_perl_version => $perl_version, module => 'modules'}
      => \&_modules_index);
    $app->routes->any("/$perl_version/:module"
      => {%defaults, perl_version => $perl_version, url_perl_version => $perl_version}
      => [module => qr/[^.]+/] => \&_perldoc);
  }

  $app->routes->any("/functions/:function" => {%defaults, module => 'functions'} => [function => qr/[^.]+/] => \&_function);
  $app->routes->any("/functions" => {%defaults, module => 'functions'} => \&_functions_index);
  $app->routes->any("/modules" => {%defaults, module => 'modules'} => \&_modules_index);
  $app->routes->any("/:module" => {%defaults} => [module => qr/[^.]+/] => \&_perldoc);
}

sub _find_pod($c, $module) {
  my $inc_dirs = $c->inc_dirs($c->stash('perl_version'));
  return Pod::Simple::Search->new->inc(0)->find($module, @$inc_dirs);
}

sub _html ($c, $src) {
  my $dom = Mojo::DOM->new(_pod_to_html($src, $c->stash('url_perl_version')));

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

  # Insert links on modules list
  if ($c->param('module') eq 'modules') {
    for my $e ($dom->find('dt')->each) {
      my $module = $e->all_text;
      $e->child_nodes->last->wrap($c->link_to('' => Mojo::URL->new("$url_prefix/$module")));
    }
  }

  # Rewrite headers
  my $highest = first { $dom->find($_)->size } qw(h1 h2 h3 h4);
  my @parts;
  for my $e ($dom->find('h1, h2, h3, h4, dt')->each) {
 
    push @parts, [] if $e->tag eq ($highest // 'h1') || !@parts;
    my $link = Mojo::URL->new->fragment($e->{id});
    my $text = $e->all_text;
    push @{$parts[-1]}, $text, $link unless $e->tag eq 'dt';
    my $permalink = $c->link_to('#' => $link, class => 'permalink');
    $e->content($permalink . $e->content);
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

  if ($c->param('module') eq 'functions') {
    # Rewrite links on function pages
    for my $e ($dom->find('a[href]')->each) {
      next unless $e->attr('href') =~ /^#(.[^-]*)/;
      my $function = url_unescape "$1";
      $e->attr(href => Mojo::URL->new("$url_prefix/functions/$function"));
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

  # Try to find a title
  my $title = $c->param('function') // $c->param('module');
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

  my $src = path($path)->slurp;
  $c->respond_to(txt => {data => $src}, html => sub { _html($c, $src) });
}

sub _function ($c) {
  my $function = $c->param('function');
  $c->stash(cpan => "https://metacpan.org/pod/perlfunc#$function");

  my $src = _get_function_pod($c, $function);
  return $c->redirect_to($c->stash('cpan')) unless defined $src;

  $c->respond_to(txt => {data => $src}, html => sub { _html($c, $src) });
}

sub _functions_index ($c) {
  $c->stash(cpan => 'https://metacpan.org/pod/perlfunc#Perl-Functions-by-Category');

  my $src = _get_function_categories($c);
  return $c->redirect_to($c->stash('cpan')) unless defined $src;

  $c->respond_to(txt => {data => $src}, html => sub { _html($c, $src) });
}

sub _modules_index ($c) {
  $c->stash(cpan => 'https://metacpan.org');

  my $src = _get_module_list($c);
  return $c->redirect_to($c->stash('cpan')) unless defined $src;

  $c->respond_to(txt => {data => $src}, html => sub { _html($c, $src) });
}

sub _get_function_pod ($c, $function) {
  my $path = _find_pod($c, 'perlfunc');
  return undef unless $path && -r $path;
  my $src = path($path)->slurp;

  my $result = _split_functions($src, $function);
  return undef unless @$result;
  return join "\n\n", '=over', @$result, '=back';
}

# Edge cases: eval, do, chop, y///, -X
sub _split_functions ($src, $function = undef) {
  my ($list_level, $started, $found_header, $found_content, $find_filetest, $found_filetest, @function, @functions) = (0);

  foreach my $para (split /\n\n+/, $src) {
    $started = 1 if !$started and $para =~ m/^=head\d Alphabetical Listing of Perl Functions/;
    next unless $started;
    next if $para =~ m/^=for Pod::Functions/;

    if ($para =~ m/^=over/) {
      $list_level++;
      next if $list_level == 1;
    }
    $list_level-- if $para =~ m/^=back/;
    next unless $list_level >= 1;

    $found_filetest = 1 if $find_filetest and $para =~ m/^\s+\Q$function\E\s/m;

    if ($list_level == 1) {
      if ($found_content and $para =~ m/^=item/) {
        if (defined $function) {
          if ($find_filetest and !$found_filetest) {
            @function = ();
            $found_header = $found_content = $find_filetest = 0;
          } else {
            last unless $para =~ m/^=item \Q$function\E(\W|$)/;
          }
        } else {
          push @functions, [@function];
          @function = ();
          $found_header = $found_content = $find_filetest = 0;
        }
      }
      $found_header = 1 if !$found_header and defined $function ? $para =~ m/^=item \Q$function\E(\W|$)/ : $para =~ m/^=item/;
      $found_header = $find_filetest = 1 if !$found_header and defined $function and $function =~ m/^-[a-zA-Z]$/ and $para =~ m/^=item -X/;
      $found_content = 1 if $found_header and $para !~ m/^=item/;
      if (defined $function and $para !~ m/^=item/ and not $found_header) {
        @function = ();
        next;
      }
    }

    push @function, $para;
  }

  return defined $function ? \@function : \@functions;
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

sub _pod_to_html ($pod, $url_perl_version = '') {
  my $parser = MetaCPAN::Pod::XHTML->new;
  $parser->perldoc_url_prefix($url_perl_version ? "/$url_perl_version/" : '/');
  $parser->$_('') for qw(html_header html_footer);
  $parser->anchor_items(1);
  $parser->output_string(\(my $output));
  return $@ unless eval { $parser->parse_string_document("$pod"); 1 };

  return $output;
}

1;
