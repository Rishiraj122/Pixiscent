-- Comments on problems. Run once in Supabase → SQL Editor (after schema.sql).

create table if not exists comments (
  id         bigserial primary key,
  problem_id text not null check (problem_id ~ '^[a-z0-9-]{1,40}$'),
  player_id  uuid not null references players on delete cascade,
  body       text not null check (char_length(body) between 1 and 2000),
  created_at timestamptz not null default now()
);
create index if not exists comments_problem on comments (problem_id, created_at);
alter table comments enable row level security;

create or replace function comments_for(p_problem text, p_secret uuid default null) returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('id', c.id, 'name', p.name, 'body', c.body, 'at', c.created_at,
           'mine', p.secret = p_secret) order by c.created_at, c.id), '[]')
  from (select * from comments where problem_id = p_problem order by created_at desc, id desc limit 300) c
  join players p on p.id = c.player_id;
$$;

create or replace function comment_counts() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_object_agg(problem_id, n), '{}') from (select problem_id, count(*) as n from comments group by problem_id) t;
$$;

create or replace function add_comment(p_secret uuid, p_problem text, p_body text) returns void
language plpgsql security definer set search_path = public as $$
declare pl players;
begin
  select * into pl from players where secret = p_secret;
  if pl.id is null then raise exception 'Join with a name before commenting.'; end if;
  p_body := btrim(coalesce(p_body, ''));
  if p_body = '' then raise exception 'Write something first.'; end if;
  if char_length(p_body) > 2000 then raise exception 'Keep comments under 2000 characters.'; end if;
  if (select count(*) from comments where player_id = pl.id and created_at > now() - interval '10 minutes') >= 5 then
    raise exception 'You are commenting a lot. Wait a few minutes and try again.';
  end if;
  insert into comments (problem_id, player_id, body) values (p_problem, pl.id, p_body);
end $$;

create or replace function delete_comment(p_secret uuid, p_id bigint) returns void
language sql security definer set search_path = public as $$
  delete from comments where id = p_id and player_id = (select id from players where secret = p_secret);
$$;

revoke all on comments from anon, authenticated;
revoke execute on function comments_for(text, uuid), comment_counts(), add_comment(uuid, text, text), delete_comment(uuid, bigint) from public;
grant execute on function comments_for(text, uuid), comment_counts(), add_comment(uuid, text, text), delete_comment(uuid, bigint) to anon, authenticated;
