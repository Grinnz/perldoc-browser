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
