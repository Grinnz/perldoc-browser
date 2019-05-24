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
  $app->helper(unindex_perl_version => \&_unindex_perl_version);
}

sub _pod_name_match ($c, $perl_version, $query) {
  my $es = $c->es;
  return undef unless _index_is_ready($es, "pods_\L$perl_version");
  my $match = $es->search(index => "pods_\L$perl_version", body => {
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
  my $es = $c->es;
  return undef unless _index_is_ready($es, "functions_\L$perl_version");
  my $match = $es->search(index => "functions_\L$perl_version", body => {
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
  my $es = $c->es;
  return undef unless _index_is_ready($es, "variables_\L$perl_version");
  my $match = $es->search(index => "variables_\L$perl_version", body => {
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
  my $es = $c->es;
  return undef unless _index_is_ready($es, "variables_\L$perl_version");
  my $match = $es->search(index => "variables_\L$perl_version", body => {
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
  my $es = $c->es;
  return [] unless _index_is_ready($es, "pods_\L$perl_version");
  $limit //= 1000;
  my $matches = $es->search(index => "pods_\L$perl_version", body => {
    query => {bool => {
      filter => {exists => {field => 'contents'}},
      should => [
        {match => {'name.text' => {query => $query, operator => 'and' }}},
        {match => {abstract => {query => $query, operator => 'and', boost => 0.4}}},
        {match => {description => {query => $query, operator => 'and', boost => 0.2}}},
        {match => {contents => {query => $query, operator => 'and', boost => 0.1}}},
      ],
      minimum_should_match => 1,
    }},
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
  my $es = $c->es;
  return [] unless _index_is_ready($es, "functions_\L$perl_version");
  $limit //= 1000;
  my $matches = $es->search(index => "functions_\L$perl_version", body => {
    query => {bool => {
      filter => {exists => {field => 'description'}},
      should => [
        {match => {'name.text' => {query => $query, operator => 'and'}}},
        {match => {description => {query => $query, operator => 'and', boost => 0.4}}},
      ],
      minimum_should_match => 1,
    }},
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
  my $es = $c->es;
  return [] unless _index_is_ready($es, "faqs_\L$perl_version");
  $limit //= 1000;
  my $matches = $es->search(index => "faqs_\L$perl_version", body => {
    query => {bool => {
      filter => {exists => {field => 'answer'}},
      should => [
        {match => {'question.text' => {query => $query, operator => 'and'}}},
        {match => {answer => {query => $query, operator => 'and', boost => 0.4}}},
      ],
      minimum_should_match => 1,
    }},
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
  my $es = $c->es;
  return [] unless _index_is_ready($es, "perldeltas_\L$perl_version");
  $limit //= 1000;
  my $matches = $es->search(index => "perldeltas_\L$perl_version", body => {
    query => {bool => {
      filter => {exists => {field => 'contents'}},
      should => [
        {match => {'heading.text' => {query => $query, operator => 'and'}}},
        {match => {contents => {query => $query, operator => 'and', boost => 0.4}}},
      ],
      minimum_should_match => 1,
    }},
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
  my $es = $c->es;
  my $time = time;
  my (%index_name, %index_alias);
  if (exists $pods->{perlfunc}) {
    $index_alias{functions} = "functions_\L$perl_version";
    $index_name{functions} = "$index_alias{functions}_$time";
  }
  if (exists $pods->{perlvar}) {
    $index_alias{variables} = "variables_\L$perl_version";
    $index_name{variables} = "$index_alias{variables}_$time";
  }
  if (all { exists $pods->{"perlfaq$_"} } 1..9) {
    $index_alias{faqs} = "faqs_\L$perl_version";
    $index_name{faqs} = "$index_alias{faqs}_$time";
  }
  if (any { m/^perl[0-9]+delta$/ } keys %$pods) {
    $index_alias{perldeltas} = "perldeltas_\L$perl_version";
    $index_name{perldeltas} = "$index_alias{perldeltas}_$time";
  }
  if ($index_pods) {
    $index_alias{pods} = "pods_\L$perl_version";
    $index_name{pods} = "$index_alias{pods}_$time";
  }
  _create_index($es, $_, $index_name{$_}, $index_alias{$_}) for keys %index_name;
  try {
    my $bulk_pod = _bulk_helper($es, $index_name{pods}, $index_alias{pods});
    foreach my $pod (keys %$pods) {
      print "Indexing $pod for $perl_version ($pods->{$pod})\n";
      my $src = path($pods->{$pod})->slurp;
      _index_pod($bulk_pod, $c->prepare_index_pod($pod, $src)) if $index_pods;
      if ($pod eq 'perlfunc') {
        print "Indexing functions for $perl_version\n";
        _index_functions($es, $index_name{functions}, $index_alias{functions}, $c->prepare_index_functions($src));
      } elsif ($pod eq 'perlvar') {
        print "Indexing variables for $perl_version\n";
        _index_variables($es, $index_name{variables}, $index_alias{variables}, $c->prepare_index_variables($src));
      } elsif (defined $index_name{faqs} and $pod =~ m/^perlfaq[1-9]$/) {
        print "Indexing $pod FAQs for $perl_version\n";
        _index_faqs($es, $index_name{faqs}, $index_alias{faqs}, $pod, $c->prepare_index_faqs($src));
      } elsif (defined $index_name{perldeltas} and $pod =~ m/^perl[0-9]+delta$/) {
        print "Indexing $pod deltas for $perl_version\n";
        _index_perldelta($es, $index_name{perldeltas}, $index_alias{perldeltas}, $pod, $c->prepare_index_perldelta($src));
      }
    }
    $bulk_pod->flush if $index_pods;
    $es->indices->forcemerge(index => [values %index_name]);
  } catch {
    $es->indices->delete(index => [values %index_name]);
    die $@;
  }
  foreach my $type (keys %index_name) {
    my $name = $index_name{$type};
    my $alias = $index_alias{$type};
    my $index_exists = $es->indices->exists_alias(name => $alias);
    my $existing_indexes = $index_exists ? [keys %{$es->indices->get_alias(name => $alias, ignore_unavailable => true)}] : [];
    print "Swapping $alias index(es) @$existing_indexes => $name\n";
    $es->indices->update_aliases(body => {actions => [
      {add => {alias => $alias, index => $name}},
      (map { +{remove => {alias => $alias, index => $_}} } @$existing_indexes),
    ]});
    $es->indices->delete(index => $existing_indexes) if @$existing_indexes;
  }
}

sub _unindex_perl_version ($c, $perl_version) {
  my $es = $c->es;
  my @indexes;
  foreach my $type (qw(pods functions variables faqs perldeltas)) {
    my $alias = "${type}_\L$perl_version";
    next unless $es->indices->exists(index => $alias);
    push @indexes, keys %{$es->indices->get(index => $alias)};
  }
  $es->indices->delete(index => \@indexes) if @indexes;
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

sub _create_index ($es, $type, $name, $index_type = $name) {
  my %body;
  $body{mappings}{$index_type}{properties} = $index_properties{$type} // {};
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
  $body{settings}{index}{number_of_shards} = 1;
  $es->indices->create(index => $name, body => \%body);
}

sub _index_pod ($bulk, $properties) {
  delete $properties->{contents} unless length $properties->{contents};
  $bulk->update({
    id => $properties->{name},
    doc => $properties,
    doc_as_upsert => true,
  });
}

sub _index_functions ($es, $index_name, $index_type, $functions) {
  my $bulk = _bulk_helper($es, $index_name, $index_type);
  foreach my $properties (@$functions) {
    delete $properties->{description} unless length $properties->{description};
    $bulk->update({
      id => $properties->{name},
      doc => $properties,
      doc_as_upsert => true,
    });
  }
  $bulk->flush;
}

sub _index_variables ($es, $index_name, $index_type, $variables) {
  my $bulk = _bulk_helper($es, $index_name, $index_type);
  foreach my $properties (@$variables) {
    $bulk->update({
      id => $properties->{name},
      doc => $properties,
      doc_as_upsert => true,
    });
  }
  $bulk->flush;
}

sub _index_faqs ($es, $index_name, $index_type, $perlfaq, $faqs) {
  my $bulk = _bulk_helper($es, $index_name, $index_type);
  foreach my $properties (@$faqs) {
    delete $properties->{answer} unless length $properties->{answer};
    $bulk->update({
      id => "${perlfaq}_$properties->{question}",
      doc => {perlfaq => $perlfaq, %$properties},
      doc_as_upsert => true,
    });
  }
  $bulk->flush;
}

sub _index_perldelta ($es, $index_name, $index_type, $perldelta, $sections) {
  my $bulk = _bulk_helper($es, $index_name, $index_type);
  foreach my $properties (@$sections) {
    delete $properties->{contents} unless length $properties->{contents};
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
