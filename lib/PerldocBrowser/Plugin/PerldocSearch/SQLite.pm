package PerldocBrowser::Plugin::PerldocSearch::SQLite;

# This software is Copyright (c) 2018 Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
use Mojo::Base 'Mojolicious::Plugin';
use List::Util 1.33 qw(all any);
use Mojo::File 'path';
use Mojo::SQLite;
use experimental 'signatures';

sub register ($self, $app, $conf) {
  my $url = $app->config->{sqlite} // $app->home->child('perldoc-browser.sqlite');
  my $sql = Mojo::SQLite->new->from_filename($url);
  $sql->migrations->from_data->migrate;
  $app->helper(sqlite => sub { $sql });

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
  my $match = $c->sqlite->db->query('SELECT "name" FROM "pods" WHERE "perl_version" = ?
    AND "name" = ? COLLATE NOCASE ORDER BY "name" = ? DESC, "name" LIMIT 1',
    $perl_version, $query, $query)->arrays->first;
  return defined $match ? $match->[0] : undef;
}

sub _function_name_match ($c, $perl_version, $query) {
  my $match = $c->sqlite->db->query('SELECT "name" FROM "functions" WHERE "perl_version" = ?
    AND "name" = ? COLLATE NOCASE ORDER BY "name" = ? DESC, "name" LIMIT 1',
    $perl_version, $query, $query)->arrays->first;
  return defined $match ? $match->[0] : undef;
}

sub _variable_name_match ($c, $perl_version, $query) {
  my $match = $c->sqlite->db->query('SELECT "name" FROM "variables" WHERE "perl_version" = ?
    AND "name" = ? COLLATE NOCASE ORDER BY "name" = ? DESC, "name" LIMIT 1',
    $perl_version, $query, $query)->arrays->first;
  return defined $match ? $match->[0] : undef;
}

sub _digits_variable_match ($c, $perl_version, $query) {
  return undef unless $query =~ m/^\$[1-9][0-9]*$/;
  my $match = $c->sqlite->db->query('SELECT "name" FROM "variables" WHERE "perl_version" = ?
    AND "name" LIKE ? ORDER BY "name" LIMIT 1',
    $perl_version, '$<digits>%')->arrays->first;
  return defined $match ? $match->[0] : undef;
}

sub _pod_search ($c, $perl_version, $query, $limit = undef) {
  my $limit_str = defined $limit ? ' LIMIT ?' : '';
  my @limit_param = defined $limit ? $limit : ();
  $query =~ s/"/""/g;
  $query = join ' ', map { qq{"$_"} } split ' ', $query;
  return $c->sqlite->db->query(q{SELECT "name", "abstract",
    snippet("pods_index", 3, '__HEADLINE_START__', '__HEADLINE_STOP__', ' ... ', 36) AS "headline"
    FROM "pods_index" WHERE "rowid" IN (SELECT "id" FROM "pods" WHERE "perl_version" = ? AND "contents" != '')
    AND "pods_index" MATCH ? ORDER BY "rank"} . $limit_str,
    $perl_version, $query, @limit_param)->hashes;
}

sub _function_search ($c, $perl_version, $query, $limit = undef) {
  my $limit_str = defined $limit ? ' LIMIT ?' : '';
  my @limit_param = defined $limit ? $limit : ();
  $query =~ s/"/""/g;
  $query = join ' ', map { qq{"$_"} } split ' ', $query;
  return $c->sqlite->db->query(q{SELECT "name",
    snippet("functions_index", 1, '__HEADLINE_START__', '__HEADLINE_STOP__', ' ... ', 36) AS "headline"
    FROM "functions_index" WHERE "rowid" IN (SELECT "id" FROM "functions" WHERE "perl_version" = ? AND "description" != '')
    AND "functions_index" MATCH ? ORDER BY "rank"} . $limit_str,
    $perl_version, $query, @limit_param)->hashes;
}

sub _faq_search ($c, $perl_version, $query, $limit = undef) {
  my $limit_str = defined $limit ? ' LIMIT ?' : '';
  my @limit_param = defined $limit ? $limit : ();
  $query =~ s/"/""/g;
  $query = join ' ', map { qq{"$_"} } split ' ', $query;
  return $c->sqlite->db->query(q{SELECT "perlfaq", "question",
    snippet("faqs_index", 1, '__HEADLINE_START__', '__HEADLINE_STOP__', ' ... ', 36) AS "headline"
    FROM "faqs_index" WHERE "rowid" IN (SELECT "id" FROM "faqs" WHERE "perl_version" = ? AND "answer" != '')
    AND "faqs_index" MATCH ? ORDER BY "rank"} . $limit_str,
    $perl_version, $query, @limit_param)->hashes;
}

sub _perldelta_search ($c, $perl_version, $query, $limit = undef) {
  my $limit_str = defined $limit ? ' LIMIT ?' : '';
  my @limit_param = defined $limit ? $limit : ();
  $query =~ s/"/""/g;
  $query = join ' ', map { qq{"$_"} } split ' ', $query;
  return $c->sqlite->db->query(q{SELECT "perldelta", "heading",
    snippet("perldeltas_index", 1, '__HEADLINE_START__', '__HEADLINE_STOP__', ' ... ', 36) AS "headline"
    FROM "perldeltas_index" WHERE "rowid" IN (SELECT "id" FROM "perldeltas" WHERE "perl_version" = ? AND "contents" != '')
    AND "perldeltas_index" MATCH ? ORDER BY "rank"} . $limit_str,
    $perl_version, $query, @limit_param)->hashes;
}

sub _index_perl_version ($c, $perl_version, $pods, $index_pods = 1) {
  my $db = $c->sqlite->db;
  my $tx = $db->begin;
  $db->delete('functions', {perl_version => $perl_version}) if exists $pods->{perlfunc};
  $db->delete('variables', {perl_version => $perl_version}) if exists $pods->{perlvar};
  $db->delete('faqs', {perl_version => $perl_version}) if all { exists $pods->{"perlfaq$_"} } 1..9;
  $db->delete('perldeltas', {perl_version => $perl_version}) if any { m/^perl[0-9]+delta$/ } keys %$pods;
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
    } elsif ($pod =~ m/^perl[0-9]+delta$/) {
      print "Indexing $pod deltas for $perl_version\n";
      _index_perldelta($db, $perl_version, $pod, $c->prepare_index_perldelta($src));
    }
  }
  $tx->commit;
}

sub _index_pod ($db, $perl_version, $properties) {
  $db->query('INSERT OR REPLACE INTO "pods"
    ("perl_version","name","abstract","description","contents") VALUES (?,?,?,?,?)',
    $perl_version, @$properties{qw(name abstract description contents)});
}

sub _index_functions ($db, $perl_version, $functions) {
  foreach my $properties (@$functions) {
    $db->query('INSERT OR REPLACE INTO "functions"
      ("perl_version","name","description") VALUES (?,?,?)',
      $perl_version, @$properties{qw(name description)});
  }
}

sub _index_variables ($db, $perl_version, $variables) {
  foreach my $properties (@$variables) {
    $db->query('INSERT OR REPLACE INTO "variables"
      ("perl_version","name") VALUES (?,?)',
      $perl_version, $properties->{name});
  }
}

sub _index_faqs ($db, $perl_version, $perlfaq, $faqs) {
  foreach my $properties (@$faqs) {
    $db->query('INSERT OR REPLACE INTO "faqs"
      ("perl_version","perlfaq","question","answer") VALUES (?,?,?,?)',
      $perl_version, $perlfaq, @$properties{qw(question answer)});
  }
}

sub _index_perldelta ($db, $perl_version, $perldelta, $sections) {
  foreach my $properties (@$sections) {
    $db->query('INSERT OR REPLACE INTO "perldeltas"
      ("perl_version","perldelta","heading","contents") VALUES (?,?,?,?)',
      $perl_version, $perldelta, @$properties{qw(heading contents)});
  }
}

1;

__DATA__
@@ migrations
--1 up
create table "pods" (
  id integer primary key autoincrement,
  perl_version text not null,
  name text not null,
  abstract text not null,
  description text not null,
  contents text not null,
  constraint "pods_perl_version_name_key" unique ("perl_version","name")
);
create index "pods_name" on "pods" ("name" collate nocase);
create virtual table "pods_index" using fts5 (
  name, abstract, description, contents,
  content='pods',
  content_rowid='id',
  tokenize='porter'
);
insert into "pods_index" ("pods_index", "rank") values ('rank', 'bm25(10.0, 4.0, 2.0, 1.0)');

create trigger "pods_ai" after insert on "pods" begin
  insert into "pods_index" ("rowid","name","abstract","description","contents")
  values (new."id",new."name",new."abstract",new."description",new."contents");
end;
create trigger "pods_ad" after delete on "pods" begin
  insert into "pods_index" ("pods_index","rowid","name","abstract","description","contents")
  values ('delete',old."id",old."name",old."abstract",old."description",old."contents");
end;
create trigger "pods_au" after update on "pods" begin
  insert into "pods_index" ("pods_index","rowid","name","abstract","description","contents")
  values ('delete',old."id",old."name",old."abstract",old."description",old."contents");
  insert into "pods_index" ("rowid","name","abstract","description","contents")
  values (new."id",new."name",new."abstract",new."description",new."contents");
end;

create table "functions" (
  id integer primary key autoincrement,
  perl_version text not null,
  name text not null,
  description text not null,
  constraint "functions_perl_version_name_key" unique ("perl_version","name")
);
create index "functions_name" on "functions" ("name" collate nocase);
create virtual table "functions_index" using fts5 (
  name, description,
  content='functions',
  content_rowid='id',
  tokenize='porter'
);
insert into "functions_index" ("functions_index", "rank") values ('rank', 'bm25(10.0, 4.0)');

create trigger "functions_ai" after insert on "functions" begin
  insert into "functions_index" ("rowid","name","description")
  values (new."id",new."name",new."description");
end;
create trigger "functions_ad" after delete on "functions" begin
  insert into "functions_index" ("functions_index","rowid","name","description")
  values ('delete',old."id",old."name",old."description");
end;
create trigger "functions_au" after update on "functions" begin
  insert into "functions_index" ("functions_index","rowid","name","description")
  values ('delete',old."id",old."name",old."description");
  insert into "functions_index" ("rowid","name","description")
  values (new."id",new."name",new."description");
end;

create table "variables" (
  id integer primary key autoincrement,
  perl_version text not null,
  name text not null,
  constraint "variables_perl_version_name_key" unique ("perl_version","name")
);
create index "variables_name" on "variables" ("name" collate nocase);

create table "faqs" (
  id integer primary key autoincrement,
  perl_version text not null,
  perlfaq text not null,
  question text not null,
  answer text not null,
  constraint "faqs_perl_version_perlfaq_question_key" unique ("perl_version","perlfaq","question")
);
create index "faqs_question" on "faqs" ("question" collate nocase);
create virtual table "faqs_index" using fts5 (
  question, answer, perlfaq unindexed,
  content='faqs',
  content_rowid='id',
  tokenize='porter'
);
insert into "faqs_index" ("faqs_index", "rank") values ('rank', 'bm25(10.0, 4.0)');

create trigger "faqs_ai" after insert on "faqs" begin
  insert into "faqs_index" ("rowid","question","answer","perlfaq")
  values (new."id",new."question",new."answer",new."perlfaq");
end;
create trigger "faqs_ad" after delete on "faqs" begin
  insert into "faqs_index" ("faqs_index","rowid","question","answer","perlfaq")
  values ('delete',old."id",old."question",old."answer",old."perlfaq");
end;
create trigger "faqs_au" after update on "faqs" begin
  insert into "faqs_index" ("faqs_index","rowid","question","answer","perlfaq")
  values ('delete',old."id",old."question",old."answer",old."perlfaq");
  insert into "faqs_index" ("rowid","question","answer","perlfaq")
  values (new."id",new."question",new."answer",new."perlfaq");
end;

--1 down
drop table if exists "pods_index";
drop table if exists "pods";
drop table if exists "functions_index";
drop table if exists "functions";
drop table if exists "variables";
drop table if exists "faqs_index";
drop table if exists "faqs";

--2 up
create table "perldeltas" (
  id integer primary key autoincrement,
  perl_version text not null,
  perldelta text not null,
  heading text not null,
  contents text not null,
  constraint "perldeltas_perl_version_perldelta_heading_key" unique ("perl_version","perldelta","heading")
);
create index "perldeltas_heading" on "perldeltas" ("heading" collate nocase);
create virtual table "perldeltas_index" using fts5 (
  heading, contents, perldelta unindexed,
  content='perldeltas',
  content_rowid='id',
  tokenize='porter'
);
insert into "perldeltas_index" ("perldeltas_index", "rank") values ('rank', 'bm25(10.0, 4.0)');

create trigger "perldeltas_ai" after insert on "perldeltas" begin
  insert into "perldeltas_index" ("rowid","heading","contents","perldelta")
  values (new."id",new."heading",new."contents",new."perldelta");
end;
create trigger "perldeltas_ad" after delete on "perldeltas" begin
  insert into "perldeltas_index" ("perldeltas_index","rowid","heading","contents","perldelta")
  values ('delete',old."id",old."heading",old."contents",old."perldelta");
end;
create trigger "perldeltas_au" after update on "perldeltas" begin
  insert into "perldeltas_index" ("perldeltas_index","rowid","heading","contents","perldelta")
  values ('delete',old."id",old."heading",old."contents",old."perldelta");
  insert into "perldeltas_index" ("rowid","heading","contents","perldelta")
  values (new."id",new."heading",new."contents",new."perldelta");
end;

--2 down
drop table if exists "perldeltas_index";
drop table if exists "perldeltas";
