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
  "new"."indexed" :=
    setweight(to_tsvector('english',"new"."name"),'A') ||
    setweight(to_tsvector('english',"new"."abstract"),'B') ||
    setweight(to_tsvector('english',"new"."description"),'C') ||
    setweight(to_tsvector('english',"new"."contents"),'D');
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
