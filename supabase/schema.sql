-- Pixiscent database. Run once in Supabase → SQL Editor.
-- Tables are closed (RLS on, no policies); the site only calls the functions below.

create extension if not exists pgcrypto;

-- ---------- players ----------
create table if not exists players (
  id         uuid primary key default gen_random_uuid(),
  secret     uuid not null unique default gen_random_uuid(),   -- the sync code, never shown to others
  name       text not null check (char_length(name) between 2 and 24),
  progress   jsonb not null default '{}',
  drafts     jsonb not null default '{}',
  easy       int not null default 0,
  medium     int not null default 0,
  hard       int not null default 0,
  score      int generated always as (easy * 10 + medium * 20 + hard * 40) stored,
  score_at   timestamptz not null default now(),                -- when the score last changed (tie-break)
  created_at timestamptz not null default now()
);
create unique index if not exists players_name_key on players (lower(name));
alter table players enable row level security;

create or replace function create_player(p_name text) returns json
language plpgsql security definer set search_path = public as $$
declare r players;
begin
  p_name := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
  if char_length(p_name) < 2 or char_length(p_name) > 24 then raise exception 'Pick a name between 2 and 24 characters.'; end if;
  if exists (select 1 from players where lower(name) = lower(p_name)) then raise exception 'That name is taken. Try another.'; end if;
  insert into players (name) values (p_name) returning * into r;
  return json_build_object('id', r.id, 'secret', r.secret, 'name', r.name);
end $$;

create or replace function load_player(p_secret uuid) returns json
language sql security definer set search_path = public as $$
  select json_build_object('id', id, 'name', name, 'progress', progress, 'drafts', drafts)
  from players where secret = p_secret;
$$;

create or replace function save_progress(p_secret uuid, p_progress jsonb, p_easy int, p_medium int, p_hard int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if octet_length(p_progress::text) > 200000 then raise exception 'Progress is too large.'; end if;
  update players set
    progress = p_progress,
    score_at = case when (easy, medium, hard) is distinct from (least(greatest(p_easy, 0), 29), least(greatest(p_medium, 0), 29), least(greatest(p_hard, 0), 12))
                    then now() else score_at end,
    easy   = least(greatest(p_easy, 0), 29),
    medium = least(greatest(p_medium, 0), 29),
    hard   = least(greatest(p_hard, 0), 12)
  where secret = p_secret;
end $$;

create or replace function save_drafts(p_secret uuid, p_drafts jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if octet_length(p_drafts::text) > 600000 then raise exception 'Drafts are too large.'; end if;
  update players set drafts = p_drafts where secret = p_secret;
end $$;

create or replace function leaderboard(p_secret uuid default null) returns json
language sql stable security definer set search_path = public as $$
  with ranked as (
    select id, name, score, easy, medium, hard, secret,
           row_number() over (order by score desc, score_at asc) as rank
    from players where score > 0
  )
  select json_build_object(
    'total', (select count(*) from ranked),
    'rows', coalesce((select json_agg(json_build_object('rank', rank, 'name', name, 'score', score, 'easy', easy,
                        'medium', medium, 'hard', hard, 'me', secret = p_secret) order by rank)
                      from ranked where rank <= 100), '[]'),
    'me', (select json_build_object('rank', rank, 'score', score) from ranked where secret = p_secret)
  );
$$;

-- ---------- weekly contests ----------
create table if not exists contests (
  id          text primary key,                      -- e.g. 'week01-washer'
  title       text not null,
  summary     text not null default '',
  metric      text not null check (metric in ('mae', 'accuracy')),
  data_url    text not null,
  starts_at   timestamptz not null,
  ends_at     timestamptz not null,
  daily_limit int not null default 5
);
create table if not exists contest_answers (
  contest_id text references contests on delete cascade,
  item_id    text,
  answer     text not null,
  split      text not null check (split in ('public', 'private')),
  primary key (contest_id, item_id)
);
create table if not exists submissions (
  id            bigserial primary key,
  contest_id    text not null references contests on delete cascade,
  player_id     uuid not null references players on delete cascade,
  public_score  double precision not null,
  private_score double precision not null,
  created_at    timestamptz not null default now()
);
create index if not exists submissions_contest on submissions (contest_id, player_id);
alter table contests enable row level security;
alter table contest_answers enable row level security;
alter table submissions enable row level security;

create or replace function list_contests() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('id', id, 'title', title, 'summary', summary, 'metric', metric,
           'data_url', data_url, 'starts_at', starts_at, 'ends_at', ends_at, 'daily_limit', daily_limit) order by starts_at), '[]')
  from contests;
$$;

-- Scores a CSV ("id,<value>" per line) against the hidden answers.
create or replace function submit_csv(p_secret uuid, p_contest text, p_csv text) returns json
language plpgsql security definer set search_path = public as $$
declare
  pl players; c contests; used int; n_missing int; n_bad int; pub double precision; priv double precision;
  day_start timestamptz := date_trunc('day', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata';
begin
  select * into pl from players where secret = p_secret;
  if pl.id is null then raise exception 'Join with a name before submitting.'; end if;
  select * into c from contests where id = p_contest;
  if c.id is null then raise exception 'No such contest.'; end if;
  if now() < c.starts_at then raise exception 'This contest has not started yet.'; end if;
  if now() > c.ends_at then raise exception 'This contest has ended.'; end if;
  if octet_length(p_csv) > 1000000 then raise exception 'The file is too large.'; end if;
  select count(*) into used from submissions where contest_id = c.id and player_id = pl.id and created_at >= day_start;
  if used >= c.daily_limit then raise exception 'You have used all % submissions for today. Try again after midnight IST.', c.daily_limit; end if;

  create temp table sub on commit drop as
    select distinct on (k) k, v from (
      select btrim(split_part(l, ',', 1)) as k, btrim(split_part(l, ',', 2)) as v, n
      from regexp_split_to_table(btrim(p_csv), E'\r?\n') with ordinality as t(l, n)
      where n > 1 and btrim(l) <> ''
    ) s order by k, n;

  select count(*) into n_missing from contest_answers a left join sub on sub.k = a.item_id
    where a.contest_id = c.id and sub.k is null;
  if n_missing > 0 then raise exception '% test ids are missing. Submit one row for every test image.', n_missing; end if;

  if c.metric = 'mae' then
    select count(*) into n_bad from contest_answers a join sub on sub.k = a.item_id
      where a.contest_id = c.id and sub.v !~ '^-?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$';
    if n_bad > 0 then raise exception '% rows have a value that is not a number.', n_bad; end if;
    select avg(abs(sub.v::float8 - a.answer::float8)) filter (where a.split = 'public'),
           avg(abs(sub.v::float8 - a.answer::float8)) filter (where a.split = 'private')
      into pub, priv from contest_answers a join sub on sub.k = a.item_id where a.contest_id = c.id;
  else
    select avg((sub.v = a.answer)::int) filter (where a.split = 'public'),
           avg((sub.v = a.answer)::int) filter (where a.split = 'private')
      into pub, priv from contest_answers a join sub on sub.k = a.item_id where a.contest_id = c.id;
  end if;

  insert into submissions (contest_id, player_id, public_score, private_score) values (c.id, pl.id, pub, priv);
  return json_build_object('score', round(pub::numeric, 4), 'left', c.daily_limit - used - 1);
end $$;

-- Live: each player's best public score. After the end: the private score of that same submission.
create or replace function contest_board(p_contest text, p_secret uuid default null) returns json
language sql stable security definer set search_path = public as $$
  with c as (select * from contests where id = p_contest),
  best as (
    select distinct on (s.player_id) s.player_id, s.public_score, s.private_score, s.created_at,
           count(*) over (partition by s.player_id) as entries
    from submissions s, c where s.contest_id = c.id
    order by s.player_id,
             case when c.metric = 'mae' then s.public_score else -s.public_score end, s.created_at
  ),
  shown as (
    select p.name, p.secret, b.entries,
           case when now() > c.ends_at then b.private_score else b.public_score end as score,
           b.created_at
    from best b join players p on p.id = b.player_id, c
  ),
  ranked as (
    select shown.*, row_number() over (order by case when c.metric = 'mae' then score else -score end, created_at) as rank
    from shown, c
  )
  select json_build_object(
    'final', (select now() > ends_at from c),
    'rows', coalesce((select json_agg(json_build_object('rank', rank, 'name', name, 'score', round(score::numeric, 4),
               'entries', entries, 'me', secret = p_secret) order by rank) from ranked where rank <= 100), '[]'),
    'me', (select json_build_object('rank', rank, 'score', round(score::numeric, 4), 'entries', entries) from ranked where secret = p_secret)
  );
$$;

-- Only these functions are reachable from the site.
revoke all on all tables in schema public from anon, authenticated;
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function create_player(text), load_player(uuid), save_progress(uuid, jsonb, int, int, int),
  save_drafts(uuid, jsonb), leaderboard(uuid), list_contests(), submit_csv(uuid, text, text),
  contest_board(text, uuid) to anon, authenticated;
