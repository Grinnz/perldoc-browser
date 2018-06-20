package PerldocBrowser::Plugin::PerldocRenderer;

# This software is Copyright (c) 2008-2018 Sebastian Riedel and others, 2018 Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
use Mojo::Base 'Mojolicious::Plugin';
use IPC::System::Simple 'capturex';
use MetaCPAN::Pod::XHTML;
use Mojo::ByteStream;
use Mojo::DOM;
use Mojo::File 'path';
use Mojo::URL;
use Pod::Simple::Search;
use experimental 'signatures';

sub register ($self, $app, $conf) {
  my $perl_versions = $conf->{perl_versions} // [];
  my $dev_versions = $conf->{dev_versions} // [];

  my %defaults = (
    perl_versions => $perl_versions,
    dev_perl_versions => $dev_versions,
    perls_dir => $conf->{perls_dir},
    module => 'perl',
    perl_version => $conf->{latest_version},
    url_perl_version => '',
  );

  foreach my $perl_version (@$perl_versions, @$dev_versions) {
    $app->routes->any("/$perl_version/functions/:function"
      => {%defaults, perl_version => $perl_version, url_perl_version => $perl_version, module => 'perlfunc'}
      => [function => qr/[^.]+/] => \&_function);
    $app->routes->any("/$perl_version/:module"
      => {%defaults, perl_version => $perl_version, url_perl_version => $perl_version}
      => [module => qr/[^.]+/] => \&_perldoc);
  }

  $app->routes->any("/functions/:function" => {%defaults, module => 'perlfunc'} => [function => qr/[^.]+/] => \&_function);
  $app->routes->any("/:module" => {%defaults} => [module => qr/[^.]+/] => \&_perldoc);
}

my %inc_dirs;
sub _inc_dirs ($perl_dir) {
  return $inc_dirs{$perl_dir} if defined $inc_dirs{$perl_dir};
  local $ENV{PERLLIB} = '';
  local $ENV{PERL5LIB} = '';
  return $inc_dirs{$perl_dir} = [split /\n+/, capturex $perl_dir->child('bin', 'perl'), '-e', 'print "$_\n" for @INC'];
}

sub _html ($c, $src, $func) {
  my $dom = Mojo::DOM->new(_pod_to_html($src, $c->stash('url_perl_version')));

  # Rewrite code blocks for syntax highlighting and correct indentation
  for my $e ($dom->find('pre > code')->each) {
    next if (my $str = $e->content) =~ /^\s*(?:\$|Usage:)\s+/m;
    next unless $str =~ /[\$\@\%]\w|-&gt;\w|^use\s+\w/m;
    my $attrs = $e->attr;
    my $class = $attrs->{class};
    $attrs->{class} = defined $class ? "$class prettyprint" : 'prettyprint';
  }

  # Rewrite headers
  my @parts;
  for my $e ($dom->find('h1, h2, h3, h4, dt')->each) {
 
    push @parts, [] if $e->tag eq 'h1' || !@parts;
    my $link = Mojo::URL->new->fragment($e->{id});
    my $text = $e->all_text;
    push @{$parts[-1]}, $text, $link unless $e->tag eq 'dt';
    my $permalink = $c->link_to('#' => $link, class => 'permalink');
    $e->content($permalink . $e->content);
  }

  # Rewrite perldoc links on perldoc perl
  if ($c->param('module') eq 'perl') {
    my $url_perl_version = $c->stash('url_perl_version');
    my $prefix = $url_perl_version ? "/$url_perl_version" : '';
    for my $e ($dom->find('pre > code')->each) {
      my $str = $e->content;
      $e->content($str) if $str =~ s/^\s*\K(perl\S+)/$c->link_to("$1" => "$prefix\/$1")/mge;
    }
    for my $e ($dom->find(':not(pre) > code')->each) {
      my $str = $e->content;
      $e->content($str) if $str =~ s/^(perldoc (\w+)$)/$c->link_to("$1" => "$prefix\/$2")/e;
    }
  }

  # Rewrite links on function pages
  if ($func) {
    my $url_perl_version = $c->stash('url_perl_version');
    my $prefix = $url_perl_version ? "/$url_perl_version" : '';
    for my $e ($dom->find('a[href]')->each) {
      next unless $e->attr('href') =~ /^#([^-]+)/;
      my $function = $1;
      $e->attr(href => $prefix . "/functions/$function");
    }
  }

  # Try to find a title
  my $title = $func ? $c->param('function') : 'Perldoc';
  $dom->find('h1 + p')->first(sub { $title = shift->text });

  # Combine everything to a proper response
  $c->content_for(perldoc => "$dom");
  $c->render('perldoc', title => $title, parts => \@parts);
}

sub _perldoc ($c) {
  # Find module or redirect to CPAN
  my $module = join '::', split('/', $c->param('module'));
  $c->stash(cpan => "https://metacpan.org/pod/$module");

  my $perl_dir = $c->stash('perls_dir')->child($c->stash('perl_version'));
  my $inc_dirs = _inc_dirs($perl_dir);

  my $path = Pod::Simple::Search->new->inc(0)->find($module, @$inc_dirs);
  return $c->redirect_to($c->stash('cpan')) unless $path && -r $path;

  my $src = path($path)->slurp;
  $c->respond_to(txt => {data => $src}, html => sub { _html($c, $src, 0) });
}

sub _function ($c) {
  my $function = $c->param('function');
  $c->stash(cpan => "https://metacpan.org/pod/perlfunc#$function");

  my $perl_dir = $c->stash('perls_dir')->child($c->stash('perl_version'));
  my $inc_dirs = _inc_dirs($perl_dir);

  my $path = Pod::Simple::Search->new->inc(0)->find('perlfunc', @$inc_dirs);
  return $c->redirect_to($c->stash('cpan')) unless $path && -r $path;

  my $src = _get_function_pod($path, $function);
  return $c->reply->not_found unless defined $src;

  $c->respond_to(txt => {data => $src}, html => sub { _html($c, $src, 1) });
}

sub _get_function_pod ($path, $function) {
  my $src = path($path)->slurp;

  my ($found, @result) = (0);

  foreach my $line (split /\n\n/, $src) {
    next if $line =~ /^=for Pod::Functions/;
    last if $found and $line =~ /^=back/m and !(grep { /^=over/m } @result);
    last if $found == 2 and $line =~ /^=item/m;
    $found = 1 if $line =~ /^=item \Q$function\E(\W|$)/m;
    $found = 2 if $found and $line !~ /^=item/m;
    if ($line !~ /^=item/m and not $found) { @result = (); next; }

    push @result, $line;
  }

  return undef unless @result;
  return join "\n\n", '=over 4', @result, '=back';
}

sub _pod_to_html ($pod, $perl_version) {
  my $parser = MetaCPAN::Pod::XHTML->new;
  $parser->perldoc_url_prefix($perl_version ? "/$perl_version/" : '/');
  $parser->$_('') for qw(html_header html_footer);
  $parser->anchor_items(1);
  $parser->output_string(\(my $output));
  return $@ unless eval { $parser->parse_string_document("$pod"); 1 };

  return $output;
}

1;
