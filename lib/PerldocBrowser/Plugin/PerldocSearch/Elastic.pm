package PerldocBrowser::Plugin::PerldocSearch::Elastic;

# This software is Copyright (c) 2018 Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
use Mojo::Base 'Mojolicious::Plugin';
use List::Util 1.33 qw(all any);
use Mojo::File 'path';
use Mojo::JSON 'true';
use Mojo::Util 'dumper';
use Search::Elasticsearch;
use Syntax::Keyword::Try;
use experimental 'signatures';

sub register ($self, $app, $conf) {
  my $url = $app->config->{es} // 'http://localhost:9200';
  my $es = Search::Elasticsearch->new(client => '6_0::Direct', nodes => $url,
    log_to => [MojoLog => logger => $app->log],
    deprecate_to => [MojoLog => logger => $app->log],
  );
  $app->helper(es => sub { $es });

  $app->helper(pod_name_match => \&_pod_name_match);
  $app->helper(function_name_match => \&_function_name_match);
  $app->helper(variable_name_match => \&_variable_name_match);
  $app->helper(digits_variable_match => \&_digits_variable_match);
  $app->helper(pod_search => \&_pod_search);
  $app->helper(function_search => \&_function_search);
  $app->helper(faq_search => \&_faq_search);
  $app->helper(perldelta_search => \&_perldelta_search);

  $app->helper(index_perl_version => \&_index_perl_version);
}

sub _pod_name_match ($c, $perl_version, $query) {
  my $es = $c->helpers->es;
  return undef unless _index_is_ready($es, "pods_$perl_version");
  my $match = $es->search(index => "pods_$perl_version", body => {
    query => {bool => {should => [
      {term => {'name.ci' => $query}},
      {term => {name => {value => $query, boost => 2.0}}},
    ]}},
    _source => 'name',
    size => 1,
    sort => ['_score'],
  });
  my $hit = $match->{hits}{hits}[0] // return undef;
  return $hit->{_source}{name};
}

sub _function_name_match ($c, $perl_version, $query) {
  my $es = $c->helpers->es;
  return undef unless _index_is_ready($es, "functions_$perl_version");
  my $match = $es->search(index => "functions_$perl_version", body => {
    query => {bool => {should => [
      {term => {'name.ci' => $query}},
      {term => {name => {value => $query, boost => 2.0}}},
    ]}},
    _source => 'name',
    size => 1,
    sort => ['_score'],
  });
  my $hit = $match->{hits}{hits}[0] // return undef;
  return $hit->{_source}{name};
}

sub _variable_name_match ($c, $perl_version, $query) {
  my $es = $c->helpers->es;
  return undef unless _index_is_ready($es, "variables_$perl_version");
  my $match = $es->search(index => "variables_$perl_version", body => {
    query => {bool => {should => [
      {term => {'name.ci' => $query}},
      {term => {name => {value => $query, boost => 2.0}}},
    ]}},
    _source => 'name',
    size => 1,
    sort => ['_score'],
  });
  my $hit = $match->{hits}{hits}[0] // return undef;
  return $hit->{_source}{name};
}

sub _digits_variable_match ($c, $perl_version, $query) {
  return undef unless $query =~ m/^\$[1-9][0-9]*$/;
  my $es = $c->helpers->es;
  return undef unless _index_is_ready($es, "variables_$perl_version");
  my $match = $es->search(index => "variables_$perl_version", body => {
    query => {prefix => {name => '$<digits>'}},
    _source => 'name',
    size => 1,
    sort => ['name'],
  });
  my $hit = $match->{hits}{hits}[0] // return undef;
  return $hit->{_source}{name};
}

my %highlight_opts = (
  type => 'unified',
  boundary_scanner => 'sentence',
  boundary_scanner_locale => 'en-US',
  fragment_size => 100,
  number_of_fragments => 2,
  pre_tags => '__HEADLINE_START__',
  post_tags => '__HEADLINE_STOP__',
);

sub _pod_search ($c, $perl_version, $query, $limit = undef) {
  my $es = $c->helpers->es;
  return [] unless _index_is_ready($es, "pods_$perl_version");
  $limit //= 1000;
  my $matches = $es->search(index => "pods_$perl_version", body => {
    query => {bool => {should => [
      {match => {'name.text' => {query => $query, operator => 'and' }}},
      {match => {abstract => {query => $query, operator => 'and', boost => 0.4}}},
      {match => {description => {query => $query, operator => 'and', boost => 0.2}}},
      {match => {contents => {query => $query, operator => 'and', boost => 0.1}}},
    ]}},
    _source => ['name','abstract'],
    highlight => {fields => {contents => {}}, %highlight_opts},
    size => $limit,
    sort => ['_score'],
  });
  my @results;
  foreach my $match (@{$matches->{hits}{hits}}) {
    my $headline = join ' ... ', @{$match->{highlight}{contents} // []};
    push @results, {
      name => $match->{_source}{name},
      abstract => $match->{_source}{abstract},
      headline => $headline,
    };
  }
  return \@results;
}

sub _function_search ($c, $perl_version, $query, $limit = undef) {
  my $es = $c->helpers->es;
  return [] unless _index_is_ready($es, "functions_$perl_version");
  $limit //= 1000;
  my $matches = $es->search(index => "functions_$perl_version", body => {
    query => {bool => {should => [
      {match => {'name.text' => {query => $query, operator => 'and'}}},
      {match => {description => {query => $query, operator => 'and', boost => 0.4}}},
    ]}},
    _source => 'name',
    highlight => {fields => {description => {}}, %highlight_opts},
    size => $limit,
    sort => ['_score'],
  });
  my @results;
  foreach my $match (@{$matches->{hits}{hits}}) {
    my $headline = join ' ... ', @{$match->{highlight}{description} // []};
    push @results, {
      name => $match->{_source}{name},
      headline => $headline,
    };
  }
  return \@results;
}

sub _faq_search ($c, $perl_version, $query, $limit = undef) {
  my $es = $c->helpers->es;
  return [] unless _index_is_ready($es, "faqs_$perl_version");
  $limit //= 1000;
  my $matches = $es->search(index => "faqs_$perl_version", body => {
    query => {bool => {should => [
      {match => {'question.text' => {query => $query, operator => 'and'}}},
      {match => {answer => {query => $query, operator => 'and', boost => 0.4}}},
    ]}},
    _source => ['perlfaq','question'],
    highlight => {fields => {answer => {}}, %highlight_opts},
    size => $limit,
    sort => ['_score'],
  });
  my @results;
  foreach my $match (@{$matches->{hits}{hits}}) {
    my $headline = join ' ... ', @{$match->{highlight}{answer} // []};
    push @results, {
      perlfaq => $match->{_source}{perlfaq},
      question => $match->{_source}{question},
      headline => $headline,
    };
  }
  return \@results;
}

sub _perldelta_search ($c, $perl_version, $query, $limit = undef) {
  my $es = $c->helpers->es;
  return [] unless _index_is_ready($es, "perldeltas_$perl_version");
  $limit //= 1000;
  my $matches = $es->search(index => "perldeltas_$perl_version", body => {
    query => {bool => {should => [
      {match => {'heading.text' => {query => $query, operator => 'and'}}},
      {match => {contents => {query => $query, operator => 'and', boost => 0.4}}},
    ]}},
    _source => ['perldelta','heading'],
    highlight => {fields => {contents => {}}, %highlight_opts},
    size => $limit,
    sort => ['_score'],
  });
  my @results;
  foreach my $match (@{$matches->{hits}{hits}}) {
    my $headline = join ' ... ', @{$match->{highlight}{contents} // []};
    push @results, {
      perldelta => $match->{_source}{perldelta},
      heading => $match->{_source}{heading},
      headline => $headline,
    };
  }
  return \@results;
}

sub _index_perl_version ($c, $perl_version, $pods, $index_pods = 1) {
  my $h = $c->helpers;
  my $es = $h->es;
  my %index_name;
  my $time = time;
  $index_name{functions} = "functions_${perl_version}_$time" if exists $pods->{perlfunc};
  $index_name{variables} = "variables_${perl_version}_$time" if exists $pods->{perlvar};
  $index_name{faqs} = "faqs_${perl_version}_$time" if all { exists $pods->{"perlfaq$_"} } 1..9;
  $index_name{perldeltas} = "perldeltas_${perl_version}_$time" if any { m/^perl[0-9]+delta$/ } keys %$pods;
  $index_name{pods} = "pods_${perl_version}_$time" if $index_pods;
  _create_index($es, $_, $perl_version, $index_name{$_}) for keys %index_name;
  try {
    my $bulk_pod = _bulk_helper($es, $index_name{pods}, "pods_$perl_version");
    foreach my $pod (keys %$pods) {
      print "Indexing $pod for $perl_version ($pods->{$pod})\n";
      my $src = path($pods->{$pod})->slurp;
      _index_pod($bulk_pod, $h->prepare_index_pod($pod, $src)) if $index_pods;
      if ($pod eq 'perlfunc') {
        print "Indexing functions for $perl_version\n";
        _index_functions($es, $index_name{functions}, $perl_version, $h->prepare_index_functions($src));
      } elsif ($pod eq 'perlvar') {
        print "Indexing variables for $perl_version\n";
        _index_variables($es, $index_name{variables}, $perl_version, $h->prepare_index_variables($src));
      } elsif (defined $index_name{faqs} and $pod =~ m/^perlfaq[1-9]$/) {
        print "Indexing $pod FAQs for $perl_version\n";
        _index_faqs($es, $index_name{faqs}, $perl_version, $pod, $h->prepare_index_faqs($src));
      } elsif (defined $index_name{perldeltas} and $pod =~ m/^perl[0-9]+delta$/) {
        print "Indexing $pod deltas for $perl_version\n";
        _index_perldelta($es, $index_name{perldeltas}, $perl_version, $pod, $h->prepare_index_perldelta($src));
      }
    }
    $bulk_pod->flush if $index_pods;
    $es->indices->forcemerge(index => [values %index_name]);
  } catch {
    $es->indices->delete(index => [values %index_name]);
    die $@;
  }
  foreach my $type (keys %index_name) {
    my $name = "${type}_$perl_version";
    my $index_exists = $es->indices->exists_alias(name => $name);
    my $existing_indexes = $index_exists ? [keys %{$es->indices->get_alias(name => $name, ignore_unavailable => true)}] : [];
    print "Swapping $name index(es) @$existing_indexes => $index_name{$type}\n";
    $es->indices->update_aliases(body => {actions => [
      {add => {alias => $name, index => $index_name{$type}}},
      (map { +{remove => {alias => $name, index => $_}} } @$existing_indexes),
    ]});
    $es->indices->delete(index => $existing_indexes) if @$existing_indexes;
  }
}

my %index_properties = (
  pods => {
    name => {type => 'keyword', fields => {text => {type => 'text'}, ci => {type => 'keyword', normalizer => 'ci_ascii'}}},
    abstract => {type => 'text'},
    description => {type => 'text'},
    contents => {type => 'text', index_options => 'offsets'},
  },
  functions => {
    name => {type => 'keyword', fields => {text => {type => 'text'}, ci => {type => 'keyword', normalizer => 'ci_ascii'}}},
    description => {type => 'text', index_options => 'offsets'},
  },
  variables => {
    name => {type => 'keyword', fields => {ci => {type => 'keyword', normalizer => 'ci_ascii'}}},
  },
  faqs => {
    perlfaq => {type => 'keyword'},
    question => {type => 'keyword', fields => {text => {type => 'text'}}},
    answer => {type => 'text', index_options => 'offsets'},
  },
  perldeltas => {
    perldelta => {type => 'keyword'},
    heading => {type => 'keyword', fields => {text => {type => 'text'}}},
    contents => {type => 'text', index_options => 'offsets'},
  },
);

sub _create_index ($es, $type, $perl_version, $name) {
  my %body;
  $body{mappings}{"${type}_$perl_version"}{properties} = $index_properties{$type} // {};
  $body{settings}{analysis} = {
    analyzer => {
      default => {
        type => 'custom',
        tokenizer => 'whitespace',
        filter => [qw(subwords english_stop asciifolding lowercase english_stemmer)],
      },
    },
    filter => {
      english_stemmer => {type => 'stemmer', language => 'english'},
      english_stop => {type => 'stop', stopwords => '_english_', ignore_case => true},
      subwords => {type => 'word_delimiter_graph', preserve_original => true, catenate_all => true},
    },
    normalizer => {
      ci_ascii => {type => 'custom', filter => [qw(asciifolding lowercase)]},
    },
  };
  $es->indices->create(index => $name, body => \%body);
}

sub _index_pod ($bulk, $properties) {
  $bulk->update({
    id => $properties->{name},
    doc => $properties,
    doc_as_upsert => true,
  });
}

sub _index_functions ($es, $index_name, $perl_version, $functions) {
  my $bulk = _bulk_helper($es, $index_name, "functions_$perl_version");
  foreach my $properties (@$functions) {
    $bulk->update({
      id => $properties->{name},
      doc => $properties,
      doc_as_upsert => true,
    });
  }
  $bulk->flush;
}

sub _index_variables ($es, $index_name, $perl_version, $variables) {
  my $bulk = _bulk_helper($es, $index_name, "variables_$perl_version");
  foreach my $properties (@$variables) {
    $bulk->update({
      id => $properties->{name},
      doc => $properties,
      doc_as_upsert => true,
    });
  }
  $bulk->flush;
}

sub _index_faqs ($es, $index_name, $perl_version, $perlfaq, $faqs) {
  my $bulk = _bulk_helper($es, $index_name, "faqs_$perl_version");
  foreach my $properties (@$faqs) {
    $bulk->update({
      id => "${perlfaq}_$properties->{question}",
      doc => {perlfaq => $perlfaq, %$properties},
      doc_as_upsert => true,
    });
  }
  $bulk->flush;
}

sub _index_perldelta ($es, $index_name, $perl_version, $perldelta, $sections) {
  my $bulk = _bulk_helper($es, $index_name, "perldeltas_$perl_version");
  foreach my $properties (@$sections) {
    $bulk->update({
      id => "${perldelta}_$properties->{heading}",
      doc => {perldelta => $perldelta, %$properties},
      doc_as_upsert => true,
    });
  }
  $bulk->flush;
}

sub _index_is_ready ($es, $index) {
  return 0 unless $es->indices->exists(index => $index);
  my $health = $es->cluster->health(level => 'indices', index => $index);
  my @indices = values %{$health->{indices}};
  return 0 if !@indices or any { ($_->{status} // 'red') eq 'red' } @indices;
  return 1;
}

sub _bulk_helper ($es, $index, $type) {
  return $es->bulk_helper(index => $index, type => $type,
    on_conflict => sub {
      my ($action, $response) = @_;
      warn "Bulk conflict [$action]: " . dumper($response);
    },
    on_error => sub {
      my ($action, $response) = @_;
      die "Bulk error [$action]: " . dumper($response);
    },
  );
}

1;
