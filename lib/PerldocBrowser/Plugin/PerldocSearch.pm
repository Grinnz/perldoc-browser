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
  my $backend = $app->config->{search_backend} // 'none';

  if ($backend eq 'none') {
    return 1;
  } elsif ($backend eq 'pg' or $backend eq 'postgres' or $backend eq 'postgresql') {
    $app->plugin('PerldocSearch::Pg');
    $app->search_backend('pg');
  } elsif ($backend eq 'es' or $backend eq 'elastic' or $backend eq 'elasticsearch') {
    $app->plugin('PerldocSearch::Elastic');
    $app->search_backend('es');
  } elsif ($backend eq 'sqlite') {
    $app->plugin('PerldocSearch::SQLite');
    $app->search_backend('sqlite');
  } else {
    die "Unknown search_backend '$backend' configured\n";
  }

  $app->helper(prepare_index_pod => \&_prepare_index_pod);
  $app->helper(prepare_index_functions => \&_prepare_index_functions);
  $app->helper(prepare_index_variables => \&_prepare_index_variables);
  $app->helper(prepare_index_faqs => \&_prepare_index_faqs);
  $app->helper(prepare_index_perldelta => \&_prepare_index_perldelta);

  my $latest_perl_version = $app->latest_perl_version;

  foreach my $perl_version (@{$app->all_perl_versions}, '') {
    my $versioned = $app->routes->any("/$perl_version" => [format => ['html']])->to(
      module => 'search',
      perl_version => length $perl_version ? $perl_version : $latest_perl_version,
      url_perl_version => $perl_version,
      format => undef, # format extension optional
    );
    $versioned->any('/search' => \&_search);
  }
}

sub _search ($c) {
  if ($c->req->url->path =~ m/\.html\z/i) {
    my $url = $c->url_with->to_abs;
    $url->path->[-1] =~ s/\.html\z//i if @{$url->path};
    $c->res->code(301);
    return $c->redirect_to($url);
  }

  $c->stash(page_name => 'search');
  my $query = trim($c->param('q') // '');
  $c->stash(cpan => Mojo::URL->new('https://metacpan.org/search')->query(q => $query));

  my $perl_version = $c->stash('perl_version');
  my $url_perl_version = $c->stash('url_perl_version');
  my $url_prefix = $url_perl_version ? $c->append_url_path('/', $url_perl_version) : '';
  my $limit = $c->param('limit') // 20;
  $limit = 20 unless $limit =~ m/\A[0-9]+\z/;
  my $no_redirect = $c->param('no_redirect');
  my $search_type = $c->param('type');

  unless ($no_redirect or $search_type) {
    my $function = $c->function_name_match($perl_version, $query);
    return $c->res->code(301) && $c->redirect_to($c->url_for($c->append_url_path("$url_prefix/functions/", $function))) if defined $function;

    my $variable = $c->variable_name_match($perl_version, $query);
    return $c->res->code(301) && $c->redirect_to($c->url_for($c->append_url_path("$url_prefix/variables/", $variable))) if defined $variable;

    my $digits = $c->digits_variable_match($perl_version, $query);
    return $c->res->code(301) && $c->redirect_to($c->url_for($c->append_url_path("$url_prefix/variables/", $digits))) if defined $digits;

    my $pod = $c->pod_name_match($perl_version, $query);
    return $c->res->code(301) && $c->redirect_to($c->url_for($c->append_url_path("$url_prefix/", $pod))) if defined $pod;
  }

  my $search_limit = $limit ? $limit+1 : undef;
  my ($function_results, $faq_results, $perldelta_results, $pod_results);
  $function_results = $c->function_search($perl_version, $query, $search_limit) if !$search_type or $search_type eq 'functions';
  $faq_results = $c->faq_search($perl_version, $query, $search_limit) if !$search_type or $search_type eq 'faqs';
  $perldelta_results = $c->perldelta_search($perl_version, $query, $search_limit) if !$search_type or $search_type eq 'perldeltas';
  $pod_results = $c->pod_search($perl_version, $query, $search_limit) if !$search_type or $search_type eq 'pods';

  my @paras = ('=encoding UTF-8');
  if (!$search_type or $search_type eq 'faqs') {
    push @paras, '=head2 FAQ', '=over';
    my $more_faqs;
    if (@$faq_results) {
      if ($limit) {
        $more_faqs = @$faq_results > $limit;
        splice @$faq_results, $limit;
      }
      foreach my $faq (@$faq_results) {
        my ($perlfaq, $question, $headline) = ($faq->{perlfaq}, map { $c->escape_pod($_) } @$faq{'question','headline'});
        $headline =~ s/__HEADLINE_START__/I<<< B<< /g;
        $headline =~ s/__HEADLINE_STOP__/ >> >>>/g;
        $headline =~ s/\n+/ /g;
        $headline = trim $headline;
        push @paras, qq{=item L<$perlfaq/"$question">\n\n$headline};
      }
    } else {
      push @paras, '=item I<No results>';
    }
    push @paras, '=back';
    if ($more_faqs) {
      my $more_url = $c->url_with("$url_prefix/search")->to_abs->query({limit => 0, type => 'faqs'});
      push @paras, "I<< More results found. Refine your search terms or L<show all FAQ results|$more_url>. >>";
    }
  }
  if (!$search_type or $search_type eq 'functions') {
    push @paras, '=head2 Functions', '=over';
    my $more_functions;
    if (@$function_results) {
      if ($limit) {
        $more_functions = @$function_results > $limit;
        splice @$function_results, $limit;
      }
      foreach my $function (@$function_results) {
        my ($name, $headline) = map { $c->escape_pod($_) } @$function{'name','headline'};
        my $desc = $c->function_description($perl_version, $name);
        $headline =~ s/__HEADLINE_START__/I<<< B<< /g;
        $headline =~ s/__HEADLINE_STOP__/ >> >>>/g;
        $headline =~ s/\n+/ /g;
        $headline = trim $headline;
        my $item = qq{L<perlfunc/"$name">};
        $item .= " - $desc" if defined $desc;
        push @paras, "=item $item\n\n$headline";
      }
    } else {
      push @paras, '=item I<No results>';
    }
    push @paras, '=back';
    if ($more_functions) {
      my $more_url = $c->url_with("$url_prefix/search")->to_abs->query({limit => 0, type => 'functions'});
      push @paras, "I<< More results found. Refine your search terms or L<show all function results|$more_url>. >>";
    }
  }
  if (!$search_type or $search_type eq 'pods') {
    push @paras, '=head2 Documentation', '=over';
    my $more_pods;
    if (@$pod_results) {
      if ($limit) {
        $more_pods = @$pod_results > $limit;
        splice @$pod_results, $limit;
      }
      foreach my $page (@$pod_results) {
        my ($name, $abstract, $headline) = map { $c->escape_pod($_) } @$page{'name','abstract','headline'};
        $headline =~ s/__HEADLINE_START__/I<<< B<< /g;
        $headline =~ s/__HEADLINE_STOP__/ >> >>>/g;
        $headline =~ s/\n+/ /g;
        $headline = trim $headline;
        push @paras, "=item L<$name> - $abstract\n\n$headline";
      }
    } else {
      push @paras, '=item I<No results>';
    }
    push @paras, '=back';
    if ($more_pods) {
      my $more_url = $c->url_with("$url_prefix/search")->to_abs->query({limit => 0, type => 'pods'});
      push @paras, "I<< More results found. Refine your search terms or L<show all documentation results|$more_url>. >>";
    }
  }
  if (!$search_type or $search_type eq 'perldeltas') {
    push @paras, '=head2 Perldeltas', '=over';
    my $more_perldeltas;
    if (@$perldelta_results) {
      if ($limit) {
        $more_perldeltas = @$perldelta_results > $limit;
        splice @$perldelta_results, $limit;
      }
      foreach my $delta (@$perldelta_results) {
        my ($perldelta, $heading, $headline) = ($delta->{perldelta}, map { $c->escape_pod($_) } @$delta{'heading','headline'});
        $headline =~ s/__HEADLINE_START__/I<<< B<< /g;
        $headline =~ s/__HEADLINE_STOP__/ >> >>>/g;
        $headline =~ s/\n+/ /g;
        $headline = trim $headline;
        push @paras, qq{=item L<$perldelta/"$heading">\n\n$headline};
      }
    } else {
      push @paras, '=item I<No results>';
    }
    push @paras, '=back';
    if ($more_perldeltas) {
      my $more_url = $c->url_with("$url_prefix/search")->to_abs->query({limit => 0, type => 'perldeltas'});
      push @paras, "I<< More results found. Refine your search terms or L<show all perldelta results|$more_url>. >>";
    }
  }
  my $src = join "\n\n", @paras;

  $c->render_perldoc_html($c->prepare_perldoc_html($src, $url_perl_version, 'search'));
}

sub _prepare_index_pod ($c, $name, $src) {
  my %properties = (name => $name, abstract => '', description => '', contents => '');

  unless ($name eq 'perltoc' or $name =~ m/^perlfaq/ or $name =~ m/^perl[0-9]+delta$/) {
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

sub _prepare_index_perldelta ($c, $src) {
  my $blocks = $c->split_perldelta($src);
  my %sections;
  foreach my $block (@$blocks) {
    my %headings;
    foreach my $para (@$block) {
      # 0: navigatable, 1: navigatable and returned in search results
      if ($para =~ m/^=head\d/) {
        my $heading = $c->pod_to_text_content("=pod\n\n$para");
        $headings{$heading} = 1;
      }
    }
    push @{$sections{$_}}, $headings{$_} ? @$block : () for keys %headings;
  }

  my @sections;
  foreach my $heading (keys %sections) {
    my $contents = $c->pod_to_text_content(join "\n\n", '=pod', @{$sections{$heading}});
    push @sections, {heading => $heading, contents => $contents};
  }

  return \@sections;
}

1;
