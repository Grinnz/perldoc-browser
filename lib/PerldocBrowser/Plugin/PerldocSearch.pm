package PerldocBrowser::Plugin::PerldocSearch;

# This software is Copyright (c) 2018 Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
use Mojo::Base 'Mojolicious::Plugin';
use Mojo::DOM;
use Mojo::URL;
use Mojo::Util 'trim';
use experimental 'signatures';

sub register ($self, $app, $conf) {
  my $backend = $app->config->{search_backend} // 'pg';
  return 1 if $backend eq 'none';

  if ($backend eq 'pg') {
    $app->plugin('PerldocSearchPg');
  } elsif ($backend eq 'es') {
    $app->plugin('PerldocSearchElastic');
  } else {
    die "Unknown search_backend '$backend' configured\n";
  }

  $app->helper(prepare_index_pod => \&_prepare_index_pod);
  $app->helper(prepare_index_functions => \&_prepare_index_functions);
  $app->helper(prepare_index_variables => \&_prepare_index_variables);
  $app->helper(prepare_index_faqs => \&_prepare_index_faqs);

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

  my $function = $c->function_name_match($query);
  return $c->redirect_to(Mojo::URL->new("$url_prefix/functions/")->path($function)) if defined $function;

  my $variable = $c->variable_name_match($query);
  return $c->redirect_to(Mojo::URL->new("$url_prefix/variables/")->path($variable)) if defined $variable;

  my $digits = $c->digits_variable_match($query);
  return $c->redirect_to(Mojo::URL->new("$url_prefix/variables/")->path($digits)) if defined $digits;

  my $pod = $c->pod_name_match($query);
  return $c->redirect_to(Mojo::URL->new("$url_prefix/")->path($pod)) if defined $pod;

  my $function_results = $c->function_search($query);
  my $faq_results = $c->faq_search($query);
  my $pod_results = $c->pod_search($query);

  my @paras = ('=encoding UTF-8');
  push @paras, '=head2 FAQ', '=over';
  if (@$faq_results) {
    foreach my $faq (@$faq_results) {
      my ($perlfaq, $question, $headline) = ($faq->{perlfaq}, map { $c->escape_pod($_) } @$faq{'question','headline'});
      $headline =~ s/__HEADLINE_START__/I<<< B<< /g;
      $headline =~ s/__HEADLINE_STOP__/ >> >>>/g;
      $headline =~ s/\n+/ /g;
      push @paras, qq{=item L<$perlfaq/"$question">\n\n$headline};
    }
  } else {
    push @paras, '=item I<No results>';
  }
  push @paras, '=back', '=head2 Functions', '=over';
  if (@$function_results) {
    foreach my $function (@$function_results) {
      my ($name, $headline) = map { $c->escape_pod($_) } @$function{'name','headline'};
      $headline =~ s/__HEADLINE_START__/I<<< B<< /g;
      $headline =~ s/__HEADLINE_STOP__/ >> >>>/g;
      $headline =~ s/\n+/ /g;
      push @paras, qq{=item L<perlfunc/"$name">\n\n$headline};
    }
  } else {
    push @paras, '=item I<No results>';
  }
  push @paras, '=back', '=head2 Documentation', '=over';
  if (@$pod_results) {
    foreach my $page (@$pod_results) {
      my ($name, $abstract, $headline) = map { $c->escape_pod($_) } @$page{'name','abstract','headline'};
      $headline =~ s/__HEADLINE_START__/I<<< B<< /g;
      $headline =~ s/__HEADLINE_STOP__/ >> >>>/g;
      $headline =~ s/\n+/ /g;
      push @paras, "=item L<$name> - $abstract\n\n$headline";
    }
  } else {
    push @paras, '=item I<No results>';
  }
  push @paras, '=back';
  my $src = join "\n\n", @paras;

  $c->respond_to(txt => {data => $src}, html => sub { $c->render_perldoc_html($src) });
}

sub _prepare_index_pod ($c, $name, $src) {
  my %properties = (name => $name, abstract => '', description => '', contents => '');

  unless ($name eq 'perltoc' or $name =~ m/^perlfaq/) {
    my $dom = Mojo::DOM->new($c->pod_to_html($src, undef, 0));
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

  return \%properties;
}

sub _prepare_index_functions ($c, $src) {
  my $blocks = $c->split_functions($src);
  my %functions;
  foreach my $block (@$blocks) {
    my ($list_level, $is_filetest, $indexed_name, %names) = (0);
    foreach my $para (@$block) {
      $list_level++ if $para =~ m/^=over/;
      $list_level-- if $para =~ m/^=back/;
      # 0: navigatable, 1: navigatable and returned in search results
      if (!$list_level and $para =~ m/^=item/) {
        my $heading = $c->pod_to_text_content("=over\n\n$para\n\n=back");
        if ($heading =~ m/^([-\w\/]+)/) {
          $names{"$1"} //= $indexed_name ? 0 : 1;
          $indexed_name = 1;
        }
        $names{"$1"} //= 0 if $heading =~ m/^([-\w]+)/;
        $is_filetest = 1 if $heading =~ m/^-X\b/;
      }
      do { $names{"$_"} //= 0 for $para =~ m/^\s+(-[a-zA-Z])\s/mg } if $is_filetest;
    }
    push @{$functions{$_}}, $names{$_} ? @$block : () for keys %names;
  }

  my @functions;
  foreach my $function (keys %functions) {
    my $pod = join "\n\n", '=over', @{$functions{$function}}, '=back';
    my $description = $c->pod_to_text_content($pod);

    push @functions, {name => $function, description => $description};
  }

  return \@functions;
}

sub _prepare_index_variables ($c, $src) {
  my $blocks = $c->split_variables($src);
  my %variables;
  foreach my $block (@$blocks) {
    my ($list_level, %names) = (0);
    foreach my $para (@$block) {
      $list_level++ if $para =~ m/^=over/;
      $list_level-- if $para =~ m/^=back/;
      # 0: navigatable, 1: navigatable and returned in search results
      if (!$list_level and $para =~ m/^=item/) {
        my $heading = $c->pod_to_text_content("=over\n\n$para\n\n=back");
        $names{"$1"} = 0 if $heading =~ m/^([\$\@%].+)$/ or $heading =~ m/^([a-zA-Z]+)$/;
      }
    }
    push @{$variables{$_}}, $names{$_} ? @$block : () for keys %names;
  }

  my @variables;
  foreach my $variable (keys %variables) {
    my $pod = join "\n\n", '=over', @{$variables{$variable}}, '=back';
    my $description = $c->pod_to_text_content($pod);

    push @variables, {name => $variable};
  }

  return \@variables;
}

sub _prepare_index_faqs ($c, $src) {
  my $blocks = $c->split_faqs($src);
  my %faqs;
  foreach my $block (@$blocks) {
    my %questions;
    foreach my $para (@$block) {
      # 0: navigatable, 1: navigatable and returned in search results
      if ($para =~ m/^=head2/) {
        my $heading = $c->pod_to_text_content("=pod\n\n$para");
        $questions{$heading} = 1;
      }
    }
    push @{$faqs{$_}}, $questions{$_} ? @$block : () for keys %questions;
  }

  my @faqs;
  foreach my $question (keys %faqs) {
    my $answer = $c->pod_to_text_content(join "\n\n", '=pod', @{$faqs{$question}});

    push @faqs, {question => $question, answer => $answer};
  }

  return \@faqs;
}

1;
