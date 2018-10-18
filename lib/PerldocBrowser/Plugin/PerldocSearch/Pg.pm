package PerldocBrowser::Plugin::PerldocSearch::Pg;

# This software is Copyright (c) 2018 Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
use Mojo::Base 'Mojolicious::Plugin';
use List::Util 1.33 'all';
use Mojo::File 'path';
use Mojo::Pg;
use experimental 'signatures';

sub register ($self, $app, $conf) {
  my $url = $app->config->{pg} // die "Postgresql connection must be configured in 'pg'\n";
  my $pg = Mojo::Pg->new($url);
  $pg->migrations->from_data->migrate;
  $app->helper(pg => sub { $pg });

  $app->helper(pod_name_match => \&_pod_name_match);
  $app->helper(function_name_match => \&_function_name_match);
  $app->helper(variable_name_match => \&_variable_name_match);
  $app->helper(digits_variable_match => \&_digits_variable_match);
  $app->helper(pod_search => \&_pod_search);
  $app->helper(function_search => \&_function_search);
  $app->helper(faq_search => \&_faq_search);

  $app->helper(index_perl_version => \&_index_perl_version);
}

sub _pod_name_match ($c, $perl_version, $query) {
  my $match = $c->pg->db->query('SELECT "name" FROM "pods" WHERE "perl_version" = $1
    AND lower("name") = lower($2) ORDER BY "name" = $2 DESC, "name" LIMIT 1',
    $perl_version, $query)->arrays->first;
  return defined $match ? $match->[0] : undef;
}

sub _function_name_match ($c, $perl_version, $query) {
  my $match = $c->pg->db->query('SELECT "name" FROM "functions" WHERE "perl_version" = $1
    AND lower("name") = lower($2) ORDER BY "name" = $2 DESC, "name" LIMIT 1',
    $perl_version, $query)->arrays->first;
  return defined $match ? $match->[0] : undef;
}

sub _variable_name_match ($c, $perl_version, $query) {
  my $match = $c->pg->db->query('SELECT "name" FROM "variables" WHERE "perl_version" = $1
    AND lower("name") = lower($2) ORDER BY "name" = $2 DESC, "name" LIMIT 1',
    $perl_version, $query)->arrays->first;
  return defined $match ? $match->[0] : undef;
}

sub _digits_variable_match ($c, $perl_version, $query) {
  return undef unless $query =~ m/^\$[1-9][0-9]*$/;
  my $match = $c->pg->db->query('SELECT "name" FROM "variables" WHERE "perl_version" = $1
    AND lower("name") LIKE lower($2) ORDER BY "name" LIMIT 1',
    $perl_version, '$<digits>%')->arrays->first;
  return defined $match ? $match->[0] : undef;
}

my $headline_opts = 'StartSel="__HEADLINE_START__", StopSel="__HEADLINE_STOP__", MaxWords=15, MinWords=10, MaxFragments=2';

sub _pod_search ($c, $perl_version, $query, $limit = undef) {
  my $limit_str = defined $limit ? ' LIMIT $4' : '';
  my @limit_param = defined $limit ? $limit : ();
  $query =~ tr!/.!  !; # postgres likes to tokenize foo.bar and foo/bar funny
  return $c->pg->db->query(q{SELECT "name", "abstract",
    ts_rank_cd("indexed", plainto_tsquery('english_tag', $1), 1) AS "rank",
    ts_headline('english_tag', "contents", plainto_tsquery('english_tag', $1), $2) AS "headline"
    FROM "pods" WHERE "perl_version" = $3 AND "indexed" @@ plainto_tsquery('english_tag', $1)
    ORDER BY "rank" DESC, "name"} . $limit_str, $query, $headline_opts, $perl_version, @limit_param)->hashes;
}

sub _function_search ($c, $perl_version, $query, $limit = undef) {
  my $limit_str = defined $limit ? ' LIMIT $4' : '';
  my @limit_param = defined $limit ? $limit : ();
  $query =~ tr!/.!  !;
  return $c->pg->db->query(q{SELECT "name",
    ts_rank_cd("indexed", plainto_tsquery('english_tag', $1), 1) AS "rank",
    ts_headline('english_tag', "description", plainto_tsquery('english_tag', $1), $2) AS "headline"
    FROM "functions" WHERE "perl_version" = $3 AND "indexed" @@ plainto_tsquery('english_tag', $1)
    ORDER BY "rank" DESC, "name"} . $limit_str, $query, $headline_opts, $perl_version, @limit_param)->hashes;
}

sub _faq_search ($c, $perl_version, $query, $limit = undef) {
  my $limit_str = defined $limit ? ' LIMIT $4' : '';
  my @limit_param = defined $limit ? $limit : ();
  $query =~ tr!/.!  !;
  return $c->pg->db->query(q{SELECT "perlfaq", "question",
    ts_rank_cd("indexed", plainto_tsquery('english_tag', $1), 1) AS "rank",
    ts_headline('english_tag', "answer", plainto_tsquery('english_tag', $1), $2) AS "headline"
    FROM "faqs" WHERE "perl_version" = $3 AND "indexed" @@ plainto_tsquery('english_tag', $1)
    ORDER BY "rank" DESC, "question"} . $limit_str, $query, $headline_opts, $perl_version, @limit_param)->hashes;
}

sub _index_perl_version ($c, $perl_version, $pods, $index_pods = 1) {
  my $db = $c->pg->db;
  my $tx = $db->begin;
  $db->delete('functions', {perl_version => $perl_version}) if exists $pods->{perlfunc};
  $db->delete('variables', {perl_version => $perl_version}) if exists $pods->{perlvar};
  $db->delete('faqs', {perl_version => $perl_version}) if all { exists $pods->{"perlfaq$_"} } 1..9;
  $db->delete('pods', {perl_version => $perl_version}) if $index_pods;
  foreach my $pod (keys %$pods) {
    print "Indexing $pod for $perl_version ($pods->{$pod})\n";
    my $src = path($pods->{$pod})->slurp;
    _index_pod($db, $perl_version, $c->prepare_index_pod($pod, $src)) if $index_pods;
    if ($pod eq 'perlfunc') {
      print "Indexing functions for $perl_version\n";
      _index_functions($db, $perl_version, $c->prepare_index_functions($src));
    } elsif ($pod eq 'perlvar') {
      print "Indexing variables for $perl_version\n";
      _index_variables($db, $perl_version, $c->prepare_index_variables($src));
    } elsif ($pod =~ m/^perlfaq[1-9]$/) {
      print "Indexing $pod FAQs for $perl_version\n";
      _index_faqs($db, $perl_version, $pod, $c->prepare_index_faqs($src));
    }
  }
  $tx->commit;
}

sub _index_pod ($db, $perl_version, $properties) {
  $db->insert('pods', {
    perl_version => $perl_version,
    %$properties,
  }, {on_conflict => \['("perl_version","name")
    do update set "abstract"=EXCLUDED."abstract", "description"=EXCLUDED."description",
    "contents"=EXCLUDED."contents"']}
  );
}

sub _index_functions ($db, $perl_version, $functions) {
  foreach my $properties (@$functions) {
    $db->insert('functions', {
      perl_version => $perl_version,
      %$properties,
    }, {on_conflict => \['("perl_version","name") do update set
      "description"=EXCLUDED."description"']}
    );
  }
}

sub _index_variables ($db, $perl_version, $variables) {
  foreach my $properties (@$variables) {
    $db->insert('variables', {
      perl_version => $perl_version,
      %$properties,
    }, {on_conflict => \['("perl_version","name") do nothing']}
    );
  }
}

sub _index_faqs ($db, $perl_version, $perlfaq, $faqs) {
  foreach my $properties (@$faqs) {
    $db->insert('faqs', {
      perl_version => $perl_version,
      perlfaq => $perlfaq,
      %$properties,
    }, {on_conflict => \['("perl_version","perlfaq","question") do update set
      "answer"=EXCLUDED."answer"']}
    );
  }
}

1;

__DATA__
@@ migrations
--1 up
create table "pods" (
  id serial primary key,
  perl_version text not null,
  name text not null,
  abstract text not null,
  description text not null,
  contents text not null,
  indexed tsvector not null,
  constraint "pods_perl_version_name_key" unique ("perl_version","name")
);
create index "pods_indexed" on "pods" using gin ("indexed");
create index "pods_name" on "pods" (lower("name") text_pattern_ops);

create table "functions" (
  id serial primary key,
  perl_version text not null,
  name text not null,
  description text not null,
  indexed tsvector not null,
  constraint "functions_perl_version_name_key" unique ("perl_version","name")
);
create index "functions_indexed" on "functions" using gin ("indexed");
create index "functions_name" on "functions" (lower("name") text_pattern_ops);

create or replace function "pods_update_indexed"() returns trigger as $$
begin
  "new"."indexed" := case when "new"."contents"='' then to_tsvector('') else
    setweight(to_tsvector('english',"new"."name"),'A') ||
    setweight(to_tsvector('english',"new"."abstract"),'B') ||
    setweight(to_tsvector('english',"new"."description"),'C') ||
    setweight(to_tsvector('english',"new"."contents"),'D') end;
  return new;
end
$$ language plpgsql;

create or replace function "functions_update_indexed"() returns trigger as $$
begin
  "new"."indexed" := case when "new"."description"='' then to_tsvector('') else
    setweight(to_tsvector('english',"new"."name"),'A') ||
    setweight(to_tsvector('english',"new"."description"),'B') end;
  return new;
end
$$ language plpgsql;

create trigger "pods_indexed_trigger" before insert or update on "pods"
  for each row execute procedure pods_update_indexed();

create trigger "functions_indexed_trigger" before insert or update on "functions"
  for each row execute procedure functions_update_indexed();

--1 down
drop table if exists "pods";
drop table if exists "functions";
drop function if exists "pods_update_indexed";
drop function if exists "functions_update_indexed";

--2 up
create table "variables" (
  id serial primary key,
  perl_version text not null,
  name text not null,
  description text not null,
  indexed tsvector not null,
  constraint "variables_perl_version_name_key" unique ("perl_version","name")
);
create index "variables_indexed" on "variables" using gin ("indexed");
create index "variables_name" on "variables" (lower("name") text_pattern_ops);

create or replace function "variables_update_indexed"() returns trigger as $$
begin
  "new"."indexed" := case when "new"."description"='' then to_tsvector('') else
    setweight(to_tsvector('english',"new"."name"),'A') ||
    setweight(to_tsvector('english',"new"."description"),'B') end;
  return new;
end
$$ language plpgsql;

create trigger "variables_indexed_trigger" before insert or update on "variables"
  for each row execute procedure variables_update_indexed();

--2 down
drop table if exists "variables";
drop function if exists "variables_update_indexed";

--3 up
create table "faqs" (
  id serial primary key,
  perl_version text not null,
  perlfaq text not null,
  question text not null,
  answer text not null,
  indexed tsvector not null,
  constraint "faqs_perl_version_perlfaq_question_key" unique ("perl_version","perlfaq","question")
);
create index "faqs_indexed" on "faqs" using gin ("indexed");
create index "faqs_question" on "faqs" (lower("question") text_pattern_ops);

create or replace function "faqs_update_indexed"() returns trigger as $$
begin
  "new"."indexed" := case when "new"."answer"='' then to_tsvector('') else
    setweight(to_tsvector('english',"new"."question"),'A') ||
    setweight(to_tsvector('english',"new"."answer"),'B') end;
  return new;
end
$$ language plpgsql;

create trigger "faqs_indexed_trigger" before insert or update on "faqs"
  for each row execute procedure faqs_update_indexed();

--3 down
drop table if exists "faqs";
drop function if exists "faqs_update_indexed";

--4 up
drop trigger if exists "variables_indexed_trigger" on "variables";
drop function if exists "variables_update_indexed"();
alter table "variables" drop column "description", drop column "indexed";

create or replace function "pods_update_indexed"() returns trigger as $$
begin
  "new"."indexed" := case when "new"."contents"='' then to_tsvector('') else
    setweight(to_tsvector('english',translate("new"."name",'/.','  ')),'A') ||
    setweight(to_tsvector('english',translate("new"."abstract",'/.','  ')),'B') ||
    setweight(to_tsvector('english',translate("new"."description",'/.','  ')),'C') ||
    setweight(to_tsvector('english',translate("new"."contents",'/.','  ')),'D') end;
  return new;
end
$$ language plpgsql;

create or replace function "functions_update_indexed"() returns trigger as $$
begin
  "new"."indexed" := case when "new"."description"='' then to_tsvector('') else
    setweight(to_tsvector('english',translate("new"."name",'/.','  ')),'A') ||
    setweight(to_tsvector('english',translate("new"."description",'/.','  ')),'B') end;
  return new;
end
$$ language plpgsql;

create or replace function "faqs_update_indexed"() returns trigger as $$
begin
  "new"."indexed" := case when "new"."answer"='' then to_tsvector('') else
    setweight(to_tsvector('english',translate("new"."question",'/.','  ')),'A') ||
    setweight(to_tsvector('english',translate("new"."answer",'/.','  ')),'B') end;
  return new;
end
$$ language plpgsql;

--4 down
alter table "variables" add column "description" text not null, add column "indexed" tsvector not null;

--5 up
create text search configuration "english_tag" (copy = "english");
alter text search configuration "english_tag" add mapping for tag, entity with simple;

create or replace function "pods_update_indexed"() returns trigger as $$
begin
  "new"."indexed" := case when "new"."contents"='' then to_tsvector('') else
    setweight(to_tsvector('english_tag',translate("new"."name",'/.','  ')),'A') ||
    setweight(to_tsvector('english_tag',translate("new"."abstract",'/.','  ')),'B') ||
    setweight(to_tsvector('english_tag',translate("new"."description",'/.','  ')),'C') ||
    setweight(to_tsvector('english_tag',translate("new"."contents",'/.','  ')),'D') end;
  return new;
end
$$ language plpgsql;

create or replace function "functions_update_indexed"() returns trigger as $$
begin
  "new"."indexed" := case when "new"."description"='' then to_tsvector('') else
    setweight(to_tsvector('english_tag',translate("new"."name",'/.','  ')),'A') ||
    setweight(to_tsvector('english_tag',translate("new"."description",'/.','  ')),'B') end;
  return new;
end
$$ language plpgsql;

create or replace function "faqs_update_indexed"() returns trigger as $$
begin
  "new"."indexed" := case when "new"."answer"='' then to_tsvector('') else
    setweight(to_tsvector('english_tag',translate("new"."question",'/.','  ')),'A') ||
    setweight(to_tsvector('english_tag',translate("new"."answer",'/.','  ')),'B') end;
  return new;
end
$$ language plpgsql;

--5 down
drop text search configuration if exists "english_tag";
